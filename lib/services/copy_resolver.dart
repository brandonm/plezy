import 'dart:async';

import '../exceptions/media_server_exceptions.dart';
import '../media/copy_selection.dart';
import '../media/library_change_event.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_item_merge.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../media/title_copies.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import '../utils/library_content_notifier.dart';
import '../utils/media_server_http_client.dart';
import '../utils/media_server_timeouts.dart';
import 'copy_pick_store.dart';
import 'data_aggregation_service.dart';
import 'multi_server_manager.dart';

/// How long one lookup's copies are reused before a read asks again.
const copyLookupTtl = Duration(minutes: 5);

/// An item's copies across the profile's servers, best first.
class ResolvedCopies {
  const ResolvedCopies({
    required this.copies,
    this.failedServerIds = const {},
    this.cancelledServerIds = const {},
    this.unqueriedServerIds = const {},
    this.aliases = const {},
  });

  /// Best first, on servers online right now. The opened item is included
  /// once, as the object the caller passed, whatever the lookup returned
  /// for it.
  final List<MediaItem> copies;

  /// Servers that failed, were cancelled, or were never asked, kept apart
  /// as the lookups report them. None of them says the title is absent.
  final Set<String> failedServerIds;
  final Set<String> cancelledServerIds;
  final Set<String> unqueriedServerIds;

  /// The catalogue aliases remembered picks are filed under: the movie's
  /// IDs, or the show's for an episode ([copyAliases]).
  final Set<String> aliases;
}

/// Finds an item's copies across the profile's servers, caches them, and
/// hands them back best-first. One per profile session.
///
/// Every read filters the cached copies to [MultiServerManager.visibleOnlineClients],
/// overlays fresh watch state and sorts by the current priority, so a server
/// powering off, progress made since, or a re-ranked library show up without
/// a lookup. Cached copies live [copyLookupTtl]. A server is re-asked alone
/// when it comes online (in the background) or re-authenticates (before the
/// read answers); a library-change event naming a library a copy sits in
/// drops the entry. Lookup failures come back as the opened item alone.
class CopyResolver {
  /// [priority] is read on every read; [freshWatchState] is
  /// `WatchStateStore.apply`.
  CopyResolver({
    required this._serverManager,
    required this._aggregation,
    required this._priority,
    required this._freshWatchState,
    this._now = DateTime.now,
  }) {
    _libraryEvents = LibraryContentNotifier().stream.listen(_onLibraryChanged);
  }

  final MultiServerManager _serverManager;
  final DataAggregationService _aggregation;
  final List<String> Function() _priority;
  final MediaItem Function(MediaItem) _freshWatchState;
  final DateTime Function() _now;

  /// By the opened item's global key, and by the show's for show copies.
  final Map<String, _Entry> _entries = {};
  final Map<String, Future<_Entry>> _loading = {};

  /// Aborted on [dispose]; every lookup runs under it. A caller's own abort
  /// only stops that caller waiting, since others may share the lookup.
  final AbortController _lifetime = AbortController();
  StreamSubscription<LibraryChangeEvent>? _libraryEvents;
  bool _disposed = false;

  /// Copies of a movie or show; an episode goes to [episodeCopiesOf].
  Future<ResolvedCopies> copiesOf(MediaItem item, {AbortController? abort}) => switch (item.kind) {
    MediaKind.episode => episodeCopiesOf(item, abort: abort),
    MediaKind.movie || MediaKind.show => _resolve(item, () => _lookUpTitle(item), abort),
    _ => Future.value(_alone(item)),
  };

  /// Copies of [episode]: its show's copies (cached under the show), each
  /// asked for the same season and episode number.
  Future<ResolvedCopies> episodeCopiesOf(MediaItem episode, {AbortController? abort}) {
    if (episode.seriesGlobalKey == null || episode.parentIndex == null || episode.index == null) {
      return Future.value(_alone(episode));
    }
    return _resolve(episode, () => _lookUpEpisode(episode), abort);
  }

  /// The cached answer for [item], filtered, overlaid and sorted like any
  /// read, or null when nothing fresh is cached. Never does I/O, so it starts
  /// no refetch either. An episode whose show is cached but which was never
  /// asked for itself is null.
  ResolvedCopies? peek(MediaItem item) {
    final entry = _entries[item.globalKey];
    if (entry == null || _isExpired(entry)) return null;
    return _view(entry, item);
  }

  bool get isDisposed => _disposed;

  /// Drops the cache and aborts lookups in flight; later reads answer with
  /// the opened item alone.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifetime.abort();
    unawaited(_libraryEvents?.cancel());
    _libraryEvents = null;
    _entries.clear();
    _loading.clear();
  }

  Future<ResolvedCopies> _resolve(MediaItem item, Future<_Entry> Function() lookUp, AbortController? abort) async {
    if (_disposed) return _alone(item);
    try {
      final entry = await _waitUnless(abort, _current(item.globalKey, lookUp));
      return _disposed ? _alone(item) : _view(entry, item);
    } catch (error, stackTrace) {
      if (abort?.isAborted ?? false) rethrow;
      if (!_disposed) appLogger.w('Copy lookup failed for ${item.globalKey}', error: error, stackTrace: stackTrace);
      return _alone(item);
    }
  }

  /// [future], unless [abort] fires first: then the caller stops waiting
  /// with a cancellation, and the shared lookup carries on for the others.
  static Future<T> _waitUnless<T>(AbortController? abort, Future<T> future) {
    if (abort == null) return future;
    abort.throwIfAborted();
    return Future.any([future, abort.trigger.then<T>((_) => throw _cancelled('Copy lookup wait'))]);
  }

  /// The entry under [key], fresh: loaded (or re-loaded past the TTL), with
  /// re-authenticated servers re-asked before it is returned, and servers
  /// that came online since (or whose leg was cancelled, which says nothing
  /// about what they hold, on a later read) re-asked in the background, or
  /// before it is returned when [awaitNewServers]. A failed leg waits for the
  /// TTL, so a slow server isn't asked again on every read.
  Future<_Entry> _current(String key, Future<_Entry> Function() lookUp, {bool awaitNewServers = false}) async {
    var entry = _entries[key];
    final loaded = entry == null || _isExpired(entry);
    if (loaded) entry = await _load(key, lookUp);
    final online = _serverManager.visibleOnlineClients;
    final reauthenticated = {
      for (final MapEntry(key: serverId, value: client) in online.entries)
        if (entry.scopes[serverId] case final scope? when !scope.matches(client)) serverId,
    };
    final cameOnline = {
      for (final serverId in online.keys)
        if (!entry.scopes.containsKey(serverId) || (!loaded && entry.cancelled.contains(serverId))) serverId,
    };
    if (reauthenticated.isNotEmpty || (awaitNewServers && cameOnline.isNotEmpty)) {
      await _refetchLegs(key, entry, {...reauthenticated, ...cameOnline});
    } else if (cameOnline.isNotEmpty) {
      unawaited(_refetchLegs(key, entry, cameOnline));
    }
    return entry;
  }

  /// One lookup per [key] at a time: concurrent reads share it.
  Future<_Entry> _load(String key, Future<_Entry> Function() lookUp) {
    final pending = _loading[key];
    if (pending != null) return pending;
    _entries.removeWhere((_, entry) => _isExpired(entry));
    final future = lookUp().then((entry) {
      if (!_disposed) _entries[key] = entry;
      return entry;
    });
    _loading[key] = future;
    future.whenComplete(() {
      if (identical(_loading[key], future)) _loading.remove(key);
    }).ignore();
    return future;
  }

  /// Re-asks [serverIds] for [entry] and folds the answers in, if [entry] is
  /// still the one cached under [key]. A server already being re-asked is
  /// not asked twice.
  Future<void> _refetchLegs(String key, _Entry entry, Set<String> serverIds) {
    final start = serverIds.difference(entry.refetching.keys.toSet());
    if (start.isNotEmpty) {
      final future = entry
          .lookUpLegs(start)
          .then(
            (legs) {
              if (!_disposed && identical(_entries[key], entry)) entry.absorb(legs);
            },
            onError: (Object error, StackTrace stackTrace) {
              appLogger.w('Copy lookup refetch failed for $key on $start', error: error, stackTrace: stackTrace);
            },
          );
      for (final serverId in start) {
        entry.refetching[serverId] = future;
      }
      future.whenComplete(() {
        for (final serverId in start) {
          if (identical(entry.refetching[serverId], future)) entry.refetching.remove(serverId);
        }
      }).ignore();
    }
    return Future.wait({for (final serverId in serverIds) entry.refetching[serverId] ?? Future<void>.value()});
  }

  bool _isExpired(_Entry entry) => _now().difference(entry.fetchedAt) > copyLookupTtl;

  /// [entry]'s copies on servers online now (and under the session they were
  /// fetched with), the opened item swapped in for its own row, overlaid and
  /// sorted.
  ResolvedCopies _view(_Entry entry, MediaItem opened) {
    final online = _serverManager.visibleOnlineClients;
    bool live(MediaItem copy) {
      final client = online[copy.serverId];
      final scope = entry.scopes[copy.serverId];
      return client != null && (scope == null || scope.matches(client));
    }

    final ownShow = entry.ownShow;
    final own = ownShow == null ? opened : stampFromShow(opened, ownShow);
    final copies = [
      if (online.containsKey(opened.serverId)) own,
      for (final serverCopies in entry.copiesByServer.values)
        for (final copy in serverCopies)
          if (copy.globalKey != opened.globalKey && live(copy)) copy,
    ].map(_freshWatchState).toList()..sort(compareCopiesByPriority(_priority()));
    return ResolvedCopies(
      copies: copies,
      failedServerIds: {...entry.failed},
      cancelledServerIds: {...entry.cancelled},
      unqueriedServerIds: {...entry.unqueried},
      aliases: {...entry.aliases},
    );
  }

  /// After [dispose] the closures may read a torn-down session: not called.
  ResolvedCopies _alone(MediaItem item) => ResolvedCopies(copies: [_disposed ? item : _freshWatchState(item)]);

  /// The servers in [serverIds] that are visible and online now.
  Map<String, MediaServerClient> _clientsIn(Set<String> serverIds) => {
    for (final entry in _serverManager.visibleOnlineClients.entries)
      if (serverIds.contains(entry.key)) entry.key: entry.value,
  };

  Set<String> _allOnline() => _serverManager.visibleOnlineClients.keys.toSet();

  /// [itemId]'s catalogue IDs from [serverId], or none when that server is
  /// offline or can't say.
  Future<ExternalIds> _idsOf(String? serverId, String? itemId) async {
    final client = _serverManager.visibleOnlineClients[serverId];
    if (client == null || itemId == null) return const ExternalIds();
    try {
      return await client.fetchExternalIds(itemId);
    } catch (error, stackTrace) {
      appLogger.w('Could not read external IDs of $serverId:$itemId', error: error, stackTrace: stackTrace);
      return const ExternalIds();
    }
  }

  /// A movie (by its IDs and Plex guid) or a show (by its IDs, else title).
  Future<_Entry> _lookUpTitle(MediaItem item) async {
    final ids = await _idsOf(item.serverId, item.id);
    final plexGuid = item.backend == MediaBackend.plex ? item.guid : null;
    final isShow = item.kind == MediaKind.show;
    final query = isShow
        ? _showQuery(title: item.title, year: item.year, ids: ids, plexGuid: plexGuid)
        : TitleQuery.movie(title: item.title ?? '', year: item.year, ids: ids, plexGuid: plexGuid);
    final kind = isShow ? MediaKind.show : MediaKind.movie;
    return _titleEntry(kind, query, ids);
  }

  /// The show [episode] belongs to, asked by its show's IDs and title.
  Future<_Entry> _lookUpShowOf(MediaItem episode) async {
    final ids = await _idsOf(episode.serverId, episode.grandparentId);
    return _titleEntry(MediaKind.show, _showQuery(title: episode.grandparentTitle, ids: ids), ids);
  }

  /// [findShowCopiesAcrossServers] reads only the show half of an episode
  /// query; the numbers are unused.
  static TitleQuery _showQuery({String? title, int? year, required ExternalIds ids, String? plexGuid}) =>
      TitleQuery.episode(
        showTitle: title ?? '',
        showYear: year,
        showIds: ids,
        showPlexGuid: plexGuid,
        season: 0,
        episode: 0,
      );

  Future<_Entry> _titleEntry(MediaKind kind, TitleQuery query, ExternalIds ids) async {
    Future<_Legs> lookUpLegs(Set<String> serverIds) async {
      final clients = _clientsIn(serverIds);
      final scopes = {for (final entry in clients.entries) entry.key: _Scope(entry.value)};
      final result = kind == MediaKind.show
          ? await _aggregation.findShowCopiesAcrossServers(query, abort: _lifetime, serverIds: clients.keys.toSet())
          : await _aggregation.findTitleCopiesAcrossServers(query, abort: _lifetime, serverIds: clients.keys.toSet());
      return _Legs(
        scopes: scopes,
        copies: result.items,
        failed: result.failedServerIds,
        cancelled: result.cancelledServerIds,
        unqueried: result.unqueriedServerIds,
        aliases: copyAliases(kind, [ids, for (final copy in result.items) _inlineIds(copy)]),
      );
    }

    final entry = _Entry(fetchedAt: _now(), lookUpLegs: lookUpLegs);
    entry.absorb(await lookUpLegs(_allOnline()));
    return entry;
  }

  /// Each of the show's copies asked for [episode]'s numbers. A candidate is
  /// kept only when [acceptEpisodeCopy] says it is the same episode.
  Future<_Entry> _lookUpEpisode(MediaItem episode) async {
    final showKey = episode.seriesGlobalKey!;
    Future<_Entry> show() => _current(showKey, () => _lookUpShowOf(episode), awaitNewServers: true);
    final ownIds = await _idsOf(episode.serverId, episode.id);

    Future<_Legs> lookUpLegs(Set<String> serverIds) async {
      final shows = await show();
      final clients = _clientsIn(serverIds);
      final failed = <String>{};
      final cancelled = <String>{};
      final unqueried = <String>{};
      final copies = <MediaItem>[];
      Future<void> askServer(String serverId, MediaServerClient client) async {
        // The show leg's outcome is the episode leg's: no show, no episode.
        for (final (shown, into) in [
          (shows.failed, failed),
          (shows.cancelled, cancelled),
          (shows.unqueried, unqueried),
        ]) {
          if (shown.contains(serverId)) {
            into.add(serverId);
            return;
          }
        }
        final showCopies = shows.copiesByServer[serverId] ?? const <MediaItem>[];
        try {
          copies.addAll(
            await _withinLegDeadline(
              'Episode copy lookup on $serverId',
              (abort) => _episodesOn(client, showCopies, episode, ownIds, abort),
            ),
          );
        } catch (error, stackTrace) {
          if (_isCancellation(error)) {
            cancelled.add(serverId);
            appLogger.d('Cancelled: episode copy lookup on $serverId');
          } else {
            failed.add(serverId);
            appLogger.w('Episode copy lookup failed on $serverId', error: error, stackTrace: stackTrace);
          }
        }
      }

      await Future.wait([for (final entry in clients.entries) askServer(entry.key, entry.value)]);
      return _Legs(
        scopes: {for (final entry in clients.entries) entry.key: _Scope(entry.value)},
        copies: copies,
        failed: failed,
        cancelled: cancelled,
        unqueried: unqueried,
        aliases: shows.aliases,
        ownShow: shows.copiesByServer[episode.serverId]?.where((copy) => copy.globalKey == showKey).firstOrNull,
      );
    }

    final entry = _Entry(fetchedAt: _now(), lookUpLegs: lookUpLegs, showKey: showKey);
    entry.absorb(await lookUpLegs(_allOnline()));
    return entry;
  }

  /// [opened]'s episode in each of [showCopies] on [client], stamped with
  /// its show copy's library.
  Future<List<MediaItem>> _episodesOn(
    MediaServerClient client,
    List<MediaItem> showCopies,
    MediaItem opened,
    ExternalIds openedIds,
    AbortController abort,
  ) async {
    final found = <MediaItem>[];
    for (final showCopy in showCopies) {
      abort.throwIfAborted();
      final candidates = await client.episodesOf(
        showCopy,
        season: opened.parentIndex!,
        episode: opened.index!,
        abort: abort,
      );
      for (final candidate in candidates) {
        final stamped = stampFromShow(candidate, showCopy);
        // The opened episode itself; the read swaps the opened object in.
        if (stamped.globalKey == opened.globalKey) {
          found.add(stamped);
          continue;
        }
        final ids = await _candidateIds(client, candidate.id, abort);
        if (acceptEpisodeCopy(opened: opened, openedIds: openedIds, candidate: stamped, candidateIds: ids)) {
          found.add(stamped);
        }
      }
    }
    return found;
  }

  /// A candidate whose IDs can't be read is judged on its length alone.
  Future<ExternalIds> _candidateIds(MediaServerClient client, String itemId, AbortController abort) async {
    try {
      return await client.fetchExternalIds(itemId);
    } catch (error, stackTrace) {
      if (abort.isAborted || _isCancellation(error)) rethrow;
      appLogger.w('Could not read external IDs of ${client.serverId}:$itemId', error: error, stackTrace: stackTrace);
      return const ExternalIds();
    }
  }

  /// [run] under [MediaServerTimeouts.libraryLookup], aborted on expiry or
  /// [dispose]. Expiry is a failure, as in the aggregation fan-out.
  Future<T> _withinLegDeadline<T>(String operation, Future<T> Function(AbortController abort) run) {
    final leg = AbortController();
    unawaited(_lifetime.trigger.then((_) => leg.abort()));
    return run(leg).timeout(
      MediaServerTimeouts.libraryLookup,
      onTimeout: () {
        leg.abort();
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.connectionTimeout,
          message: '$operation exceeded its ${MediaServerTimeouts.libraryLookup.inSeconds}s budget',
        );
      },
    );
  }

  /// Drops entries with a copy in a library [event] names (or in any library
  /// on its server, when it names none), and the episodes of a dropped show.
  void _onLibraryChanged(LibraryChangeEvent event) {
    if (_disposed || !event.hasChanges) return;
    final serverId = event.serverId.value;
    bool covers(_Entry entry) => (entry.copiesByServer[serverId] ?? const <MediaItem>[]).any(
      (copy) => event.targetsWholeServer || event.libraryIds.contains(copy.libraryId),
    );
    final dropped = {
      for (final MapEntry(:key, :value) in _entries.entries)
        if (covers(value)) key,
    };
    if (dropped.isEmpty) return;
    _entries.removeWhere((key, entry) => dropped.contains(key) || dropped.contains(entry.showKey));
  }
}

bool _isCancellation(Object error) => error is MediaServerHttpException && error.isCancellation;

MediaServerHttpException _cancelled(String operation) =>
    MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: '$operation cancelled');

/// The catalogue IDs [copy]'s row already carries, read without a request:
/// Jellyfin's inline `ProviderIds`, or Plex's `Guid` list and legacy `guid`.
ExternalIds _inlineIds(MediaItem copy) {
  final raw = copy.raw;
  if (raw == null) return const ExternalIds();
  final providerIds = raw['ProviderIds'];
  if (providerIds is Map) return ExternalIds.fromJellyfinProviderIds(providerIds.cast<String, Object?>());
  final guids = raw['Guid'];
  final modern = guids is List ? ExternalIds.fromGuids(guids) : const ExternalIds();
  return modern.fillFrom(ExternalIds.fromLegacyPlexGuid(raw['guid']));
}

/// The session a server's leg was asked under. A different one means the
/// cached copies may be another user's view of that server.
class _Scope {
  _Scope(MediaServerClient client)
    : cacheServerId = client.cacheServerId,
      authenticationSessionId = client.authenticationSessionId;

  final String cacheServerId;
  final Object authenticationSessionId;

  bool matches(MediaServerClient client) =>
      client.cacheServerId == cacheServerId && identical(client.authenticationSessionId, authenticationSessionId);
}

/// One lookup's answer from the servers it asked.
class _Legs {
  const _Legs({
    required this.scopes,
    required this.copies,
    required this.failed,
    required this.cancelled,
    required this.unqueried,
    required this.aliases,
    this.ownShow,
  });

  /// Every server asked, with the session it was asked under.
  final Map<String, _Scope> scopes;
  final List<MediaItem> copies;
  final Set<String> failed;
  final Set<String> cancelled;
  final Set<String> unqueried;
  final Set<String> aliases;

  /// For an episode, the show copy it was opened from.
  final MediaItem? ownShow;
}

/// One cached lookup: its copies and accounting per server asked.
class _Entry {
  _Entry({required this.fetchedAt, required this.lookUpLegs, this.showKey});

  final DateTime fetchedAt;

  /// Asks the given servers again, as the first lookup asked them all.
  final Future<_Legs> Function(Set<String> serverIds) lookUpLegs;

  /// For an episode, the show entry its copies came through.
  final String? showKey;

  MediaItem? ownShow;
  final Map<String, List<MediaItem>> copiesByServer = {};
  final Map<String, _Scope> scopes = {};
  final Set<String> failed = {};
  final Set<String> cancelled = {};
  final Set<String> unqueried = {};
  final Set<String> aliases = {};
  final Map<String, Future<void>> refetching = {};

  /// Replaces what the servers [legs] asked had said with what they say now.
  void absorb(_Legs legs) {
    for (final serverId in legs.scopes.keys) {
      copiesByServer.remove(serverId);
      failed.remove(serverId);
      cancelled.remove(serverId);
      unqueried.remove(serverId);
    }
    scopes.addAll(legs.scopes);
    for (final copy in legs.copies) {
      if (copy.serverId case final serverId?) copiesByServer.putIfAbsent(serverId, () => []).add(copy);
    }
    failed.addAll(legs.failed);
    cancelled.addAll(legs.cancelled);
    unqueried.addAll(legs.unqueried);
    aliases.addAll(legs.aliases);
    ownShow ??= legs.ownShow;
  }
}
