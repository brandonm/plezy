import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_change_event.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/media/title_copies.dart';
import 'package:plezy/services/copy_resolver.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/utils/external_ids.dart';
import 'package:plezy/utils/library_content_notifier.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../test_helpers/media_items.dart';

/// One server's libraries, answering only what the copy lookups ask. Modeled
/// on `_Library` in `test/watch_together/title_copies_test.dart`.
class _Server implements MediaServerClient {
  _Server(String id, {this.backend = MediaBackend.plex}) : serverId = ServerId(id);

  @override
  final ServerId serverId;

  @override
  final MediaBackend backend;

  @override
  Object authenticationSessionId = Object();

  /// `findByExternalIds` answers per kind.
  final Map<MediaKind, List<MediaItem>> byIds = {};
  final Map<String, List<MediaItem>> children = {};
  final Map<String, ExternalIds> ids = {};

  /// Thrown by every lookup.
  Object? error;

  /// Thrown by `fetchChildren` only.
  Object? childrenError;

  /// While set, lookups wait on it.
  Completer<void>? gate;

  /// One per lookup, in order: each holds one lookup, which answers with
  /// [byIds] as it was when asked.
  final List<Completer<void>> gates = [];

  /// While set, `fetchExternalIds` waits on it.
  Completer<void>? idsGate;

  /// How long each lookup, listing and ID read takes.
  Duration delay = Duration.zero;

  final List<MediaKind> lookups = [];
  final List<String> childrenOf = [];

  int lookupsOf(MediaKind kind) => lookups.where((k) => k == kind).length;

  @override
  String? get serverName => 'Server $serverId';

  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async {
    lookups.add(kind);
    final answer = byIds[kind] ?? const <MediaItem>[];
    if (gates.isNotEmpty) await gates.removeAt(0).future;
    if (gate != null) await gate!.future;
    await _wait();
    if (error != null) throw error!;
    return answer;
  }

  Future<void> _wait() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    if (error != null) throw error!;
    return const [];
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    childrenOf.add(parentId);
    await _wait();
    if (error ?? childrenError case final failure?) throw failure;
    return children[parentId] ?? const [];
  }

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    if (idsGate != null) await idsGate!.future;
    await _wait();
    return ids[itemId] ?? const ExternalIds();
  }

  @override
  Future<MediaItem?> fetchItem(String id) async => null;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The profile's servers; [online] is what `visibleOnlineClients` returns.
class _Servers implements MultiServerManager {
  final Map<String, MediaServerClient> online = {};

  void add(_Server server) => online[server.serverId.value] = server;

  @override
  Map<String, MediaServerClient> get visibleOnlineClients => Map.of(online);

  @override
  Map<String, MediaServerClient> get onlineClients => Map.of(online);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Real aggregation that reports [unqueried] as never asked, a shape the
/// composed lookups can't produce against fakes.
class _UnqueriedAggregation extends DataAggregationService {
  _UnqueriedAggregation(super.serverManager, this.unqueried);

  final Set<String> unqueried;

  @override
  Future<LibraryLookupResult> findTitleCopiesAcrossServers(
    TitleQuery query, {
    AbortController? abort,
    Set<String>? serverIds,
  }) async {
    final result = await super.findTitleCopiesAcrossServers(query, abort: abort, serverIds: serverIds);
    return (
      items: result.items,
      succeededServerIds: result.succeededServerIds,
      cancelledServerIds: result.cancelledServerIds,
      failedServerIds: result.failedServerIds,
      unqueriedServerIds: {...result.unqueriedServerIds, ...unqueried},
    );
  }
}

List<MediaVersion> _versions(int height) => [
  MediaVersion(
    id: 'v$height',
    height: height,
    parts: const [MediaPart(id: 'p', durationMs: 7200000)],
  ),
];

MediaItem _movie(
  String id,
  String server, {
  String? library,
  int height = 1080,
  int? viewOffsetMs,
  String title = 'The Matrix',
  MediaBackend backend = MediaBackend.plex,
  Map<String, Object?>? raw,
}) => testMediaItem(
  id: id,
  backend: backend,
  kind: MediaKind.movie,
  title: title,
  year: 1999,
  serverId: server,
  serverName: 'Server $server',
  libraryId: library,
  libraryTitle: library,
  durationMs: 7200000,
  viewOffsetMs: viewOffsetMs,
  mediaVersions: _versions(height),
  raw: raw,
);

MediaItem _show(
  String id,
  String server, {
  String? library,
  MediaBackend backend = MediaBackend.plex,
  Map<String, Object?>? raw,
}) => testMediaItem(
  id: id,
  backend: backend,
  kind: MediaKind.show,
  title: 'Severance',
  year: 2022,
  serverId: server,
  serverName: 'Server $server',
  libraryId: library,
  libraryTitle: library,
  raw: raw,
);

MediaItem _episode(
  String id,
  String server, {
  required String showId,
  int season = 1,
  int episode = 2,
  String? library,
  int durationMs = 3000000,
  MediaBackend backend = MediaBackend.plex,
}) => testMediaItem(
  id: id,
  backend: backend,
  kind: MediaKind.episode,
  title: 'Episode $episode',
  serverId: server,
  serverName: 'Server $server',
  grandparentId: showId,
  grandparentTitle: 'Severance',
  parentIndex: season,
  index: episode,
  libraryId: library,
  libraryTitle: library,
  durationMs: durationMs,
  mediaVersions: _versions(1080),
);

List<String> _keys(ResolvedCopies resolved) => [for (final copy in resolved.copies) copy.globalKey];

void main() {
  late _Servers servers;
  late List<String> priority;
  late MediaItem Function(MediaItem) overlay;
  late List<CopyResolver> resolvers;

  CopyResolver resolver({DataAggregationService? aggregation, DateTime Function()? now}) {
    final created = CopyResolver(
      serverManager: servers,
      aggregation: aggregation ?? DataAggregationService(servers),
      priority: () => priority,
      freshWatchState: (item) => overlay(item),
      now: now ?? DateTime.now,
    );
    resolvers.add(created);
    return created;
  }

  setUp(() {
    servers = _Servers();
    priority = [];
    overlay = (item) => item;
    resolvers = [];
  });

  tearDown(() {
    for (final created in resolvers) {
      created.dispose();
    }
  });

  /// Plex `a` holds the opened movie in Movies; Jellyfin `b` holds another
  /// copy in Movies 4K.
  ({_Server a, _Server b, MediaItem opened}) twoServerMovie() {
    final opened = _movie('m1', 'a', library: 'movies');
    final a = _Server('a')
      ..ids['m1'] = const ExternalIds(tmdb: 603, imdb: 'tt0133093')
      ..byIds[MediaKind.movie] = [opened];
    final b = _Server('b', backend: MediaBackend.jellyfin)
      ..byIds[MediaKind.movie] = [_movie('m9', 'b', library: '4k', height: 2160, backend: MediaBackend.jellyfin)];
    servers
      ..add(a)
      ..add(b);
    return (a: a, b: b, opened: opened);
  }

  test('movie: opened item present once, using the opened object', () async {
    final opened = _movie('m1', 'a', library: 'movies', viewOffsetMs: 600000);
    // The lookup's row for the opened item is stale: no progress, old title.
    final stale = _movie('m1', 'a', library: 'movies', title: 'Matrix (old)');
    servers
      ..add(
        _Server('a')
          ..ids['m1'] = const ExternalIds(tmdb: 603)
          ..byIds[MediaKind.movie] = [stale],
      )
      ..add(_Server('b')..byIds[MediaKind.movie] = [_movie('m9', 'b', library: 'movies')]);

    final resolved = await resolver().copiesOf(opened);

    expect(_keys(resolved).where((key) => key == 'a:m1'), hasLength(1));
    expect(resolved.copies.firstWhere((copy) => copy.globalKey == 'a:m1'), same(opened));
    expect(_keys(resolved), containsAll(['a:m1', 'b:m9']));
  });

  test('movie: opened item is included even when the lookup misses it', () async {
    final opened = _movie('m1', 'a', library: 'movies');
    servers
      ..add(_Server('a')..ids['m1'] = const ExternalIds(tmdb: 603))
      ..add(_Server('b')..byIds[MediaKind.movie] = [_movie('m9', 'b', library: 'movies')]);

    final resolved = await resolver().copiesOf(opened);

    expect(_keys(resolved), unorderedEquals(['a:m1', 'b:m9']));
  });

  test('movie opened without a library stamp ranks by the library its lookup row names', () async {
    // Jellyfin Continue Watching rows carry no library.
    const jf = MediaBackend.jellyfin;
    final opened = _movie('m1', 'a', height: 1080, viewOffsetMs: 600000, backend: jf);
    servers
      ..add(
        _Server('a', backend: jf)
          ..ids['m1'] = const ExternalIds(tmdb: 603)
          ..byIds[MediaKind.movie] = [_movie('m1', 'a', library: 'remux', height: 1080, backend: jf)],
      )
      ..add(_Server('b')..byIds[MediaKind.movie] = [_movie('m9', 'b', library: 'hd', height: 2160)]);
    priority = ['a:remux', 'b:hd'];

    final resolved = await resolver().copiesOf(opened);

    expect(_keys(resolved), ['a:m1', 'b:m9']);
    final own = resolved.copies.first;
    expect(own.libraryId, 'remux');
    expect(own.libraryTitle, 'remux');
    expect(own.viewOffsetMs, 600000, reason: 'everything else is the opened object');
  });

  test('two copies on one server in two libraries both rank', () async {
    final opened = _movie('m4k', 's', library: '4k', height: 2160);
    servers.add(
      _Server('s')
        ..ids['m4k'] = const ExternalIds(tmdb: 603)
        ..byIds[MediaKind.movie] = [opened, _movie('mhd', 's', library: 'hd')],
    );
    priority = ['s:hd', 's:4k'];

    final resolved = await resolver().copiesOf(opened);

    expect(_keys(resolved), ['s:mhd', 's:m4k']);
  });

  /// Plex `plex` holds the opened episode; Jellyfin `silo` holds the show in
  /// three libraries, whose episodes arrive unstamped.
  ({_Server plex, _Server silo, MediaItem opened}) siloShow() {
    const jf = MediaBackend.jellyfin;
    final opened = _episode('pE', 'plex', showId: 'pShow', library: 'tv');
    final plex = _Server('plex')
      ..ids['pShow'] = const ExternalIds(tvdb: 371980)
      ..ids['pE'] = const ExternalIds(tvdb: 555)
      ..byIds[MediaKind.show] = [_show('pShow', 'plex', library: 'tv')]
      ..children['pShow'] = [opened];
    final silo = _Server('silo', backend: jf)
      ..byIds[MediaKind.show] = [
        _show('sHd', 'silo', library: 'hd', backend: jf),
        _show('s4k', 'silo', library: '4k', backend: jf),
        _show('sRemux', 'silo', library: 'remux', backend: jf),
      ];
    for (final library in ['Hd', '4k', 'Remux']) {
      silo.children['s$library'] = [_episode('e$library', 'silo', showId: 's$library', backend: jf)];
      silo.ids['e$library'] = const ExternalIds(tvdb: 555);
    }
    servers
      ..add(plex)
      ..add(silo);
    return (plex: plex, silo: silo, opened: opened);
  }

  test('episode copies inherit show stamps and rank Silo Remux > 4K > HD', () async {
    final fixture = siloShow();
    priority = ['silo:remux', 'silo:4k', 'silo:hd'];

    final resolved = await resolver().episodeCopiesOf(fixture.opened);

    expect(_keys(resolved), ['silo:eRemux', 'silo:e4k', 'silo:eHd', 'plex:pE']);
    expect([for (final copy in resolved.copies) copy.libraryId], ['remux', '4k', 'hd', 'tv']);
    expect(resolved.copies.last, same(fixture.opened));
  });

  test('episode lookup reuses cached show copies (one show lookup for two episodes)', () async {
    final fixture = siloShow();
    final next = _episode('pE3', 'plex', showId: 'pShow', episode: 3, library: 'tv');
    fixture.plex.children['pShow'] = [fixture.opened, next];
    final copies = resolver();

    await copies.episodeCopiesOf(fixture.opened);
    await copies.episodeCopiesOf(next);

    expect(fixture.plex.lookupsOf(MediaKind.show), 1);
    expect(fixture.silo.lookupsOf(MediaKind.show), 1);
  });

  test('renumbered episode on one server is dropped, others kept', () async {
    final fixture = siloShow();
    // HD's S01E02 is another episode: its IDs contradict the opened one's.
    fixture.silo.ids['eHd'] = const ExternalIds(tvdb: 999);
    // 4K's has no IDs and a length 30% off.
    fixture.silo.ids.remove('e4k');
    fixture.silo.children['s4k'] = [
      _episode('e4k', 'silo', showId: 's4k', durationMs: 2100000, backend: MediaBackend.jellyfin),
    ];

    final resolved = await resolver().episodeCopiesOf(fixture.opened);

    expect(_keys(resolved), unorderedEquals(['silo:eRemux', 'plex:pE']));
  });

  test('warm cache then top server goes offline: next read picks the next copy, no refetch', () async {
    final fixture = twoServerMovie();
    priority = ['b:4k', 'a:movies'];
    final copies = resolver();
    expect(_keys(await copies.copiesOf(fixture.opened)).first, 'b:m9');

    servers.online.remove('b');
    final resolved = await copies.copiesOf(fixture.opened);

    expect(_keys(resolved), ['a:m1']);
    expect(copies.peek(fixture.opened)!.copies.map((copy) => copy.globalKey), ['a:m1']);
    expect(fixture.a.lookups, hasLength(1));
    expect(fixture.b.lookups, hasLength(1));
  });

  test('server comes online: entry refetches that leg in the background', () async {
    final fixture = twoServerMovie();
    servers.online.remove('b');
    final copies = resolver();
    expect(_keys(await copies.copiesOf(fixture.opened)), ['a:m1']);

    final gate = fixture.b.gate = Completer<void>();
    servers.add(fixture.b);
    // The read answers while b's leg is still held at the gate: a read that
    // waited for it would sit there until the 20 s leg deadline.
    final resolved = await copies.copiesOf(fixture.opened).timeout(const Duration(seconds: 1));
    expect(_keys(resolved), ['a:m1']);
    await pumpEventQueue();
    expect(fixture.b.lookups, hasLength(1));

    gate.complete();
    await pumpEventQueue();
    final refreshed = await copies.copiesOf(fixture.opened);

    expect(_keys(refreshed), unorderedEquals(['a:m1', 'b:m9']));
    expect(fixture.a.lookups, hasLength(1));
    expect(fixture.b.lookups, hasLength(1));
  });

  test('authenticationSessionId change invalidates only that server', () async {
    final fixture = twoServerMovie();
    final copies = resolver();
    await copies.copiesOf(fixture.opened);

    fixture.b
      ..authenticationSessionId = Object()
      ..byIds[MediaKind.movie] = [_movie('m10', 'b', library: '4k', backend: MediaBackend.jellyfin)];
    // Without I/O, the other session's copies are withheld at once.
    expect(_keys(copies.peek(fixture.opened)!), ['a:m1']);

    final resolved = await copies.copiesOf(fixture.opened);

    expect(_keys(resolved), unorderedEquals(['a:m1', 'b:m10']));
    expect(fixture.a.lookups, hasLength(1));
    expect(fixture.b.lookups, hasLength(2));
  });

  test('TTL 5 minutes: read at 4:59 cached, at 5:01 refetched', () {
    fakeAsync((async) {
      final fixture = twoServerMovie();
      final start = DateTime(2026, 10, 24);
      final copies = resolver(now: () => start.add(async.elapsed));

      unawaited(copies.copiesOf(fixture.opened));
      async.flushMicrotasks();
      expect(fixture.a.lookups, hasLength(1));

      async.elapse(const Duration(minutes: 4, seconds: 59));
      unawaited(copies.copiesOf(fixture.opened));
      async.flushMicrotasks();
      expect(copies.peek(fixture.opened), isNotNull);
      expect(fixture.a.lookups, hasLength(1));

      async.elapse(const Duration(seconds: 2));
      expect(copies.peek(fixture.opened), isNull);
      unawaited(copies.copiesOf(fixture.opened));
      async.flushMicrotasks();
      expect(fixture.a.lookups, hasLength(2));
      expect(fixture.b.lookups, hasLength(2));
    });
  });

  test('concurrent copiesOf share one future', () async {
    final fixture = twoServerMovie();
    final gate = fixture.a.gate = Completer<void>();
    final copies = resolver();

    final first = copies.copiesOf(fixture.opened);
    final second = copies.copiesOf(fixture.opened);
    await pumpEventQueue();
    gate.complete();
    final results = await Future.wait([first, second]);

    expect(fixture.a.lookups, hasLength(1));
    expect(fixture.b.lookups, hasLength(1));
    expect(_keys(results[0]), _keys(results[1]));
    expect(_keys(results[0]), hasLength(2));
  });

  test('freshWatchState overlay applied on every read', () async {
    final fixture = twoServerMovie();
    final copies = resolver();
    overlay = (item) => item.globalKey == 'b:m9' ? item.copyWith(viewOffsetMs: 1000) : item;
    final first = await copies.copiesOf(fixture.opened);
    expect(first.copies.firstWhere((copy) => copy.globalKey == 'b:m9').viewOffsetMs, 1000);

    overlay = (item) => item.globalKey == 'b:m9' ? item.copyWith(viewOffsetMs: 2000) : item;
    final second = await copies.copiesOf(fixture.opened);
    final peeked = copies.peek(fixture.opened)!;

    expect(second.copies.firstWhere((copy) => copy.globalKey == 'b:m9').viewOffsetMs, 2000);
    expect(peeked.copies.firstWhere((copy) => copy.globalKey == 'b:m9').viewOffsetMs, 2000);
    expect(fixture.b.lookups, hasLength(1));
  });

  test('priority change re-sorts cached copies without I/O', () async {
    final fixture = twoServerMovie();
    final copies = resolver();
    priority = ['a:movies', 'b:4k'];
    expect(_keys(await copies.copiesOf(fixture.opened)), ['a:m1', 'b:m9']);

    priority = ['b:4k', 'a:movies'];

    expect(_keys(copies.peek(fixture.opened)!), ['b:m9', 'a:m1']);
    expect(_keys(await copies.copiesOf(fixture.opened)), ['b:m9', 'a:m1']);
    expect(fixture.a.lookups, hasLength(1));
    expect(fixture.b.lookups, hasLength(1));
  });

  test('accounting sets are kept distinct', () async {
    final opened = _movie('m1', 'ok', library: 'movies');
    servers
      ..add(
        _Server('ok')
          ..ids['m1'] = const ExternalIds(tmdb: 603)
          ..byIds[MediaKind.movie] = [opened],
      )
      ..add(
        _Server('failed')
          ..error = MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'refused'),
      )
      ..add(
        _Server('cancelled')
          ..error = MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'closing'),
      );

    final resolved = await resolver(aggregation: _UnqueriedAggregation(servers, {'unqueried'})).copiesOf(opened);

    expect(_keys(resolved), ['ok:m1']);
    expect(resolved.failedServerIds, {'failed'});
    expect(resolved.cancelledServerIds, {'cancelled'});
    expect(resolved.unqueriedServerIds, {'unqueried'});
  });

  test('a cancelled leg is asked again in the background; a failed one waits for the TTL', () async {
    final fixture = twoServerMovie();
    final failing = _Server('failed')
      ..error = MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'refused');
    servers.add(failing);
    fixture.b.error = MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'closing');
    final copies = resolver();
    final first = await copies.copiesOf(fixture.opened);
    expect(first.cancelledServerIds, {'b'});

    fixture.b.error = null;
    failing.error = null;
    await copies.copiesOf(fixture.opened);
    await pumpEventQueue();
    final resolved = await copies.copiesOf(fixture.opened);

    expect(_keys(resolved), unorderedEquals(['a:m1', 'b:m9']));
    expect(resolved.cancelledServerIds, isEmpty);
    expect(resolved.failedServerIds, {'failed'});
    expect(fixture.b.lookups, hasLength(2));
    expect(failing.lookups, hasLength(1));
    expect(fixture.a.lookups, hasLength(1));
  });

  test('episode: a server whose episode listing fails is accounted as failed', () async {
    final fixture = siloShow();
    // The show lookup answers; listing its episodes fails.
    servers.add(
      _Server('broken')
        ..byIds[MediaKind.show] = [_show('bShow', 'broken', library: 'tv')]
        ..childrenError = MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'refused'),
    );

    final resolved = await resolver().episodeCopiesOf(fixture.opened);

    expect(resolved.failedServerIds, {'broken'});
    expect(resolved.cancelledServerIds, isEmpty);
    expect(_keys(resolved), unorderedEquals(['silo:eRemux', 'silo:e4k', 'silo:eHd', 'plex:pE']));
  });

  test('aliases come from the query ids (show ids for an episode)', () async {
    final fixture = siloShow();
    // The Jellyfin show row already carries its provider IDs inline.
    fixture.silo.byIds[MediaKind.show] = [
      _show(
        'sHd',
        'silo',
        library: 'hd',
        backend: MediaBackend.jellyfin,
        raw: const {
          'ProviderIds': {'Tmdb': '95396'},
        },
      ),
    ];
    final copies = resolver();

    final episode = await copies.episodeCopiesOf(fixture.opened);

    expect(episode.aliases, {'show|tvdb:371980', 'show|tmdb:95396'});

    final movie = twoServerMovie();
    final resolvedMovie = await copies.copiesOf(movie.opened);

    expect(resolvedMovie.aliases, {'movie|tmdb:603', 'movie|imdb:tt0133093'});
  });

  test('a library-change event naming a covered library drops the entry', () async {
    final fixture = twoServerMovie();
    final copies = resolver();
    await copies.copiesOf(fixture.opened);

    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('a'), libraryIds: const {'music'}, itemsAdded: true),
    );
    await pumpEventQueue();
    expect(copies.peek(fixture.opened), isNotNull);

    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('a'), libraryIds: const {'movies'}, itemsAdded: true),
    );
    await pumpEventQueue();
    expect(copies.peek(fixture.opened), isNull);

    await copies.copiesOf(fixture.opened);
    expect(fixture.a.lookups, hasLength(2));
  });

  test('a library-change event during the load answers the caller but is not cached', () async {
    final fixture = twoServerMovie();
    final gate = Completer<void>();
    fixture.a.gates.add(gate);
    final copies = resolver();
    final pending = copies.copiesOf(fixture.opened);
    await pumpEventQueue();

    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('a'), libraryIds: const {'movies'}, itemsAdded: true),
    );
    await pumpEventQueue();
    gate.complete();

    expect(_keys(await pending), unorderedEquals(['a:m1', 'b:m9']));
    expect(copies.peek(fixture.opened), isNull);
    await copies.copiesOf(fixture.opened);
    expect(fixture.a.lookups, hasLength(2));
    expect(copies.peek(fixture.opened), isNotNull);
  });

  test('a background refetch finishing after a library-change drop does not bring the entry back', () async {
    final fixture = twoServerMovie();
    servers.online.remove('b');
    final copies = resolver();
    await copies.copiesOf(fixture.opened);
    final gate = Completer<void>();
    fixture.b.gates.add(gate);
    servers.add(fixture.b);
    await copies.copiesOf(fixture.opened); // starts b's leg in the background
    await pumpEventQueue();

    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('a'), libraryIds: const {'movies'}, itemsAdded: true),
    );
    await pumpEventQueue();
    expect(copies.peek(fixture.opened), isNull);
    gate.complete();
    await pumpEventQueue();

    expect(copies.peek(fixture.opened), isNull);
  });

  test('an old background refetch finishing after a TTL reload does not overwrite the fresher entry', () async {
    final fixture = twoServerMovie();
    servers.online.remove('b');
    var now = DateTime(2026, 10, 24);
    final copies = resolver(now: () => now);
    await copies.copiesOf(fixture.opened);
    final gate = Completer<void>();
    fixture.b.gates.add(gate);
    servers.add(fixture.b);
    await copies.copiesOf(fixture.opened); // b's leg in the background, held
    await pumpEventQueue();

    now = now.add(const Duration(minutes: 6));
    fixture.b.byIds[MediaKind.movie] = [_movie('mNEW', 'b', library: '4k', backend: MediaBackend.jellyfin)];
    expect(_keys(await copies.copiesOf(fixture.opened)), unorderedEquals(['a:m1', 'b:mNEW']));
    gate.complete();
    await pumpEventQueue();

    expect(_keys(copies.peek(fixture.opened)!), unorderedEquals(['a:m1', 'b:mNEW']));
  });

  test('opened item on an offline server is excluded when another copy is online', () async {
    final fixture = twoServerMovie();
    final copies = resolver();
    await copies.copiesOf(fixture.opened);

    servers.online.remove('a');

    expect(_keys(await copies.copiesOf(fixture.opened)), ['b:m9']);
    expect(_keys(copies.peek(fixture.opened)!), ['b:m9']);
  });

  test('all copies offline returns the opened item alone', () async {
    final fixture = twoServerMovie();
    final copies = resolver();
    await copies.copiesOf(fixture.opened);

    servers.online.clear();

    expect((await copies.copiesOf(fixture.opened)).copies, [same(fixture.opened)]);
    expect(copies.peek(fixture.opened)!.copies, [same(fixture.opened)]);
  });

  test('a cold episode read runs its server calls in parallel', () {
    fakeAsync((async) {
      final fixture = siloShow();
      // Two candidates in one library: their IDs are read side by side too.
      fixture.silo.children['sHd'] = [
        _episode('eHd', 'silo', showId: 'sHd', backend: MediaBackend.jellyfin),
        _episode('eHd2', 'silo', showId: 'sHd', backend: MediaBackend.jellyfin),
      ];
      fixture.silo.ids['eHd2'] = const ExternalIds(tvdb: 555);
      fixture.plex.delay = fixture.silo.delay = const Duration(milliseconds: 500);
      ResolvedCopies? resolved;

      unawaited(resolver().episodeCopiesOf(fixture.opened).then((copies) => resolved = copies));
      // In parallel: show IDs (with the episode's own IDs alongside), the show
      // lookup, the listings, the candidates' IDs: 4 x 0.5 s. Serially Silo's
      // three listings and four ID reads alone are 3.5 s.
      async.elapse(const Duration(milliseconds: 1900));
      expect(resolved, isNull);
      async.elapse(const Duration(milliseconds: 200));

      expect(resolved, isNotNull);
      expect(_keys(resolved!), hasLength(5));
    });
  });

  test('dispose releases a read waiting on an ID fetch, and nothing more is asked', () async {
    final fixture = twoServerMovie();
    final idsGate = fixture.a.idsGate = Completer<void>();
    final copies = resolver();
    ResolvedCopies? resolved;
    unawaited(copies.copiesOf(fixture.opened).then((copies) => resolved = copies));
    await pumpEventQueue();
    expect(resolved, isNull);

    copies.dispose();
    await pumpEventQueue();

    expect(resolved?.copies, [same(fixture.opened)]);
    idsGate.complete();
    await pumpEventQueue();
    expect(fixture.a.lookups, isEmpty);
    expect(fixture.b.lookups, isEmpty);
  });

  test('a stalled ID fetch gives up at the lookup deadline and the lookup goes on without IDs', () {
    fakeAsync((async) {
      final fixture = twoServerMovie();
      fixture.a.idsGate = Completer<void>();
      ResolvedCopies? resolved;

      unawaited(resolver().copiesOf(fixture.opened).then((copies) => resolved = copies));
      async.elapse(const Duration(seconds: 19));
      expect(resolved, isNull);
      async.elapse(const Duration(seconds: 2));

      expect(resolved?.copies, [same(fixture.opened)]);
      expect(resolved?.aliases, isEmpty);
    });
  });

  test('a background refetch overlapping an event on its own server is not folded in', () async {
    final fixture = twoServerMovie();
    servers.online.remove('b');
    final copies = resolver();
    await copies.copiesOf(fixture.opened);
    final gate = Completer<void>();
    fixture.b.gates.add(gate);
    servers.add(fixture.b);
    await copies.copiesOf(fixture.opened); // b's leg in the background, answer taken before the event
    await pumpEventQueue();

    // The entry has no copy on b yet, so the event does not drop it.
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('b'), libraryIds: const {'4k'}, itemsRemoved: true),
    );
    await pumpEventQueue();
    expect(copies.peek(fixture.opened), isNotNull);
    gate.complete();
    await pumpEventQueue();

    expect(_keys(copies.peek(fixture.opened)!), ['a:m1']);
    await copies.copiesOf(fixture.opened);
    await pumpEventQueue();
    expect(fixture.b.lookups, hasLength(2));
  });

  test('a show refetch discarded by an event still answers the episode read, which is not cached on it', () async {
    final fixture = siloShow();
    servers.online.remove('silo');
    final show = _show('pShow', 'plex', library: 'tv');
    final copies = resolver();
    await copies.copiesOf(show); // show entry cached without silo
    final gate = Completer<void>();
    fixture.silo.gates.add(gate);
    servers.add(fixture.silo);
    await copies.copiesOf(show); // silo's show leg re-asked in the background, held
    await pumpEventQueue();

    // An event on silo: the show entry has no silo copy, so it stays.
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('silo'), libraryIds: const {'hd'}, itemsAdded: true),
    );
    await pumpEventQueue();

    final pending = copies.episodeCopiesOf(fixture.opened); // waits on the held show refetch
    await pumpEventQueue();
    gate.complete();
    final first = await pending;

    expect(_keys(first), containsAll(['silo:eRemux', 'silo:e4k', 'silo:eHd', 'plex:pE']));
    expect(copies.peek(fixture.opened), isNull, reason: 'built on a show answer that was not cached');

    final second = await copies.episodeCopiesOf(fixture.opened);
    expect(_keys(second), containsAll(['silo:eRemux', 'silo:e4k', 'silo:eHd', 'plex:pE']));
    expect(fixture.silo.lookupsOf(MediaKind.show), 2);
    expect(copies.peek(fixture.opened), isNotNull);
  });

  test('an episode read joining a show load that overlapped an event is not cached on it', () async {
    final fixture = siloShow();
    final shows = fixture.silo.byIds[MediaKind.show]!;
    fixture.silo.byIds[MediaKind.show] = []; // Silo doesn't hold the show yet.
    final show = _show('pShow', 'plex', library: 'tv');
    final copies = resolver();
    final gate = Completer<void>();
    fixture.silo.gates.add(gate);
    final showRead = copies.copiesOf(show); // Silo has answered "none", held.
    await pumpEventQueue();

    // The show arrives on Silo, and its event with it.
    fixture.silo.byIds[MediaKind.show] = shows;
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(serverId: ServerId('silo'), libraryIds: const {'hd'}, itemsAdded: true),
    );
    await pumpEventQueue();

    final episodeRead = copies.episodeCopiesOf(fixture.opened); // joins the show load
    await pumpEventQueue();
    gate.complete();
    await showRead;
    expect(_keys(await episodeRead), ['plex:pE']);
    expect(copies.peek(show), isNull);
    expect(copies.peek(fixture.opened), isNull, reason: 'built on a show answer that was not cached');

    final second = await copies.episodeCopiesOf(fixture.opened);
    expect(_keys(second), containsAll(['silo:eRemux', 'silo:e4k', 'silo:eHd', 'plex:pE']));
  });

  test('a server whose show re-ask failed is not recorded as asked for the episode', () async {
    final fixture = siloShow();
    servers.online.remove('silo');
    final show = _show('pShow', 'plex', library: 'tv');
    final copies = resolver(aggregation: _FailOnceShowAggregation(servers, 'silo'));
    await copies.copiesOf(show); // show entry cached without silo
    servers.add(fixture.silo);

    final first = await copies.episodeCopiesOf(fixture.opened); // silo's show re-ask throws
    expect(_keys(first), ['plex:pE']);
    expect(first.unqueriedServerIds, {'silo'});

    await copies.episodeCopiesOf(fixture.opened); // silo still unasked: re-asked in the background
    await pumpEventQueue();
    final third = await copies.episodeCopiesOf(fixture.opened);

    expect(_keys(third), containsAll(['silo:eRemux', 'silo:e4k', 'silo:eHd', 'plex:pE']));
    expect(third.unqueriedServerIds, isEmpty);
  });

  test('settled reads leave nothing in flight to retain them', () async {
    final fixture = siloShow();
    final movie = twoServerMovie();
    final copies = resolver();

    await copies.copiesOf(movie.opened);
    await copies.episodeCopiesOf(fixture.opened);
    final gate = Completer<void>();
    movie.b.gates.add(gate);
    movie.b.authenticationSessionId = Object();
    final pending = copies.copiesOf(movie.opened); // waits on b's re-ask
    await pumpEventQueue();
    expect(copies.inFlightCount, greaterThan(0));
    gate.complete();
    await pending;
    await pumpEventQueue();

    expect(copies.inFlightCount, 0);
  });

  test('a lookup that throws leaves the opened item alone, uncached', () async {
    final opened = _movie('m1', 'a', library: 'movies');
    servers.add(_Server('a'));
    final aggregation = _ThrowingAggregation(servers);

    final resolved = await resolver(aggregation: aggregation).copiesOf(opened);

    expect(resolved.copies, [same(opened)]);
  });

  test('dispose discards the cache', () async {
    final fixture = twoServerMovie();
    final copies = resolver();
    await copies.copiesOf(fixture.opened);

    copies.dispose();
    // The session the closures read is gone with the resolver.
    priority = const [];
    overlay = (_) => throw StateError('read after dispose');

    expect(copies.peek(fixture.opened), isNull);
    expect(_keys(await copies.copiesOf(fixture.opened)), ['a:m1']);
    expect(fixture.a.lookups, hasLength(1));
  });

  test('a read in flight when the session is disposed answers without touching it', () async {
    final fixture = twoServerMovie();
    final gate = fixture.a.gate = Completer<void>();
    final copies = resolver();
    final pending = copies.copiesOf(fixture.opened);
    await pumpEventQueue();

    copies.dispose();
    overlay = (_) => throw StateError('read after dispose');
    gate.complete();

    expect((await pending).copies, [same(fixture.opened)]);
  });
}

/// Real aggregation whose show lookup throws once when it asks [server].
class _FailOnceShowAggregation extends DataAggregationService {
  _FailOnceShowAggregation(super.serverManager, this.server);

  final String server;
  var failed = false;

  @override
  Future<LibraryLookupResult> findShowCopiesAcrossServers(
    TitleQuery query, {
    AbortController? abort,
    Set<String>? serverIds,
  }) async {
    if (!failed && (serverIds?.contains(server) ?? false)) {
      failed = true;
      throw StateError('show re-ask failed');
    }
    return super.findShowCopiesAcrossServers(query, abort: abort, serverIds: serverIds);
  }
}

class _ThrowingAggregation extends DataAggregationService {
  _ThrowingAggregation(super.serverManager);

  @override
  Future<LibraryLookupResult> findTitleCopiesAcrossServers(
    TitleQuery query, {
    AbortController? abort,
    Set<String>? serverIds,
  }) async => throw StateError('boom');
}
