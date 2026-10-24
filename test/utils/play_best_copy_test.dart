import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openwatchparty/openwatchparty.dart' as owp;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/providers/copy_priority_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/watch_state_store.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/copy_pick_store.dart';
import 'package:plezy/services/copy_resolver.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/video_player_navigation.dart';
import 'package:plezy/watch_together/models/watch_copy.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/pump.dart';

const _minute = 60 * 1000;
const _aliases = {'movie|tmdb:603'};

/// Plain Play across servers (copy priority, spec §3): the best-ranked copy
/// plays, from the furthest progress across copies, unless the launch is an
/// explicit one or the lookup can't answer in time.
void main() {
  late StorageService storage;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    storage = await StorageService.getInstance();
  });

  tearDown(SettingsService.resetForTesting);

  // Plex holds the progress; Silo's 4K library is ranked first and Silo's HD
  // library second. Silo 4K carries a stale offset of its own, which the
  // session's watch state still reports for it.
  final plex = _movie('m-plex', 'plex', 'p-movies', viewOffsetMs: 30 * _minute);
  final silo4k = _movie(
    'm-4k',
    'silo',
    's-4k',
    viewOffsetMs: 5 * _minute,
    versions: const [MediaVersion(id: 'v4k', videoResolution: '4k', videoCodec: 'hevc', container: 'mkv')],
  );
  final siloHd = _movie(
    'm-hd',
    'silo',
    's-hd',
    versions: const [
      MediaVersion(id: 'hd-a', videoResolution: '1080', videoCodec: 'h264', container: 'mp4'),
      MediaVersion(id: 'hd-b', videoResolution: '1080', videoCodec: 'hevc', container: 'mkv'),
    ],
  );

  testWidgets('plays the top-ranked copy with the furthest viewOffsetMs', (tester) async {
    final resolver = _FakeCopyResolver.answering([silo4k, siloHd, plex]);
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage);

    final launched = await harness.play(tester, plex);

    expect(launched.metadata.globalKey, silo4k.globalKey);
    expect(launched.metadata.viewOffsetMs, 30 * _minute, reason: "Plex's progress, not Silo 4K's stale own offset");
    expect(launched.queueAnchor, isNull, reason: 'a movie has no episode queue');
    expect(resolver.asked, [plex.globalKey]);
  });

  testWidgets('remembered pick beats ranking', (tester) async {
    final resolver = _FakeCopyResolver.answering([silo4k, siloHd, plex]);
    final picks = CopyPickStore(storage, 'p1');
    await picks.write(
      _aliases,
      CopyPick(key: siloHd.globalKey, lib: 'silo:s-hd', sig: siloHd.mediaVersions![1].signature, at: 1),
    );
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage, picks: picks);

    final launched = await harness.play(tester, plex);

    expect(launched.metadata.globalKey, siloHd.globalKey);
    expect(launched.selectedMediaIndex, 1, reason: "the pick's version, by signature");
    expect(launched.metadata.viewOffsetMs, 30 * _minute);
  });

  testWidgets('a pick without a version leaves the version to the in-server preference', (tester) async {
    final resolver = _FakeCopyResolver.answering([silo4k, siloHd, plex]);
    final picks = CopyPickStore(storage, 'p1');
    await picks.write(_aliases, CopyPick(key: siloHd.globalKey, lib: 'silo:s-hd', at: 1));
    await saveMediaVersionPreferenceFor(siloHd, index: 1, versions: siloHd.mediaVersions!);
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage, picks: picks);

    final launched = await harness.play(tester, plex);

    expect(launched.metadata.globalKey, siloHd.globalKey);
    expect(launched.selectedMediaIndex, 1, reason: 'the saved in-server preference still applies');
    expect(launched.preferredVersionSignature, siloHd.mediaVersions![1].signature);
  });

  testWidgets('resolver slower than 2 s plays the opened item', (tester) async {
    final resolver = _FakeCopyResolver.pending();
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage);

    harness.start(plex);
    await tester.pump();
    expect(resolver.asked, [plex.globalKey]);
    await tester.pump(const Duration(milliseconds: 1990));
    expect(harness.launches, isEmpty, reason: 'Play waits for the lookup up to 2 s');
    expect(resolver.lastAbort!.isAborted, isFalse);

    // Past the cap: the launch follows without any more waiting.
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(harness.launches, hasLength(1), reason: 'the wait is capped at 2 s');

    final launched = harness.launches.single;
    expect(launched.metadata.globalKey, plex.globalKey);
    expect(launched.metadata.viewOffsetMs, plex.viewOffsetMs);
    expect(resolver.lastAbort!.isAborted, isTrue, reason: 'the abandoned wait is aborted');

    // A late answer changes nothing.
    resolver.complete([silo4k, plex]);
    await tester.pump();
    expect(harness.launches, hasLength(1));
  });

  testWidgets('completed download plays locally and is not retargeted', (tester) async {
    final resolver = _FakeCopyResolver.answering([silo4k, plex]);
    final harness = await _Harness.pump(
      tester,
      resolver: resolver,
      storage: storage,
      downloads: _Downloads({plex.globalKey: _download(plex, mediaIndex: 0)}),
    );

    final launched = await harness.play(tester, plex);

    expect(launched.metadata.globalKey, plex.globalKey);
    expect(resolver.asked, isEmpty, reason: 'the download decides before any lookup');
  });

  testWidgets('isOffline, explicit version, explicit initialPosition, watchTogetherCopy each bypass', (tester) async {
    final resolver = _FakeCopyResolver.answering([silo4k, plex]);
    final room = WatchCopy(serverId: 'plex', itemId: plex.id, versionId: '', item: plex);
    final harness = await _Harness.pump(
      tester,
      resolver: resolver,
      storage: storage,
      watchTogether: _RoomCopyProvider(room),
    );

    Future<VideoPlayerScreen> bypass(String why, Future<bool?> Function(BuildContext context) launch) async {
      harness.launches.clear();
      unawaited(launch(harness.context));
      await pumpUntil(tester, () => harness.launches.isNotEmpty, describe: () => 'no launch: $why');
      final launched = harness.launches.single;
      expect(launched.metadata.globalKey, plex.globalKey, reason: why);
      return launched;
    }

    final offline = await bypass('offline', (c) => playBestCopy(c, metadata: plex, isOffline: true));
    expect(offline.isOffline, isTrue);
    await bypass('explicit version', (c) => playBestCopy(c, metadata: plex, selectedMediaIndex: 0));
    await bypass('explicit source', (c) => playBestCopy(c, metadata: plex, selectedMediaSourceId: 'v0'));
    final positioned = await bypass(
      'explicit start position',
      (c) => playBestCopy(c, metadata: plex, initialPosition: const Duration(minutes: 1)),
    );
    expect(positioned.initialPosition, const Duration(minutes: 1));
    final together = await bypass('Watch Together', (c) => playBestCopy(c, metadata: plex, watchTogetherCopy: room));
    expect(together.watchTogetherCopy, room);

    expect(resolver.asked, isEmpty);
  });

  testWidgets('external player receives the furthest offset via viewOffsetMs', (tester) async {
    await (await SettingsService.getInstance()).write(SettingsService.useExternalPlayer, true);
    final launchedUrls = _mockUrlLauncher();
    final resolver = _FakeCopyResolver.answering([silo4k, plex]);
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage);

    unawaited(playBestCopy(harness.context, metadata: plex));
    await pumpUntil(tester, () => launchedUrls.isNotEmpty, describe: () => 'no external launch');

    expect(launchedUrls, ['https://silo/stream/m-4k']);
    expect(harness.clients['silo']!.externalRequests, [
      (id: 'm-4k', mediaIndex: 0, position: const Duration(minutes: 30)),
    ]);
    expect(harness.clients['plex']!.externalRequests, isEmpty);
    expect(harness.launches, isEmpty);
  });

  testWidgets('resolver error plays the opened item', (tester) async {
    final resolver = _FakeCopyResolver.failing(StateError('lookup blew up'));
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage);

    final launched = await harness.play(tester, plex);

    expect(resolver.asked, [plex.globalKey]);
    expect(launched.metadata.globalKey, plex.globalKey);
    expect(launched.metadata.viewOffsetMs, plex.viewOffsetMs);
  });

  testWidgets('retargeted episode anchors the queue to the opened episode', (tester) async {
    final opened = _episode('e2', 'plex', 'p-tv', 'show-1');
    final silo = _episode('s-e2', 'silo', 's-tv', 'silo-show');
    final resolver = _FakeCopyResolver.answering([silo, opened]);
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage);

    final launched = await harness.play(tester, opened);

    expect(launched.metadata.globalKey, silo.globalKey);
    expect(launched.queueAnchor, same(opened));

    // Not retargeted: the episode is its own queue entry.
    final own = _FakeCopyResolver.answering([opened, silo]);
    final ownHarness = await _Harness.pump(tester, resolver: own, storage: storage);
    final ownLaunch = await ownHarness.play(tester, opened);
    expect(ownLaunch.metadata.globalKey, opened.globalKey);
    expect(ownLaunch.queueAnchor, isNull);
  });

  testWidgets("the opened item's server offline: the best copy online plays", (tester) async {
    // The resolver leaves the opened item out when its server is offline.
    final resolver = _FakeCopyResolver.answering([siloHd]);
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage);

    final launched = await harness.play(tester, plex.copyWith(viewOffsetMs: null));

    expect(launched.metadata.globalKey, siloHd.globalKey);
    expect(launched.metadata.viewOffsetMs, isNull, reason: 'no copy has progress');
  });

  testWidgets('opened item on an offline server still contributes its progress', (tester) async {
    // Plex is offline, so the result holds Silo HD alone; Plex's row still
    // says where the user stopped.
    final resolver = _FakeCopyResolver.answering([siloHd]);
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage);

    final launched = await harness.play(tester, plex);
    expect(launched.metadata.globalKey, siloHd.globalKey);
    expect(launched.metadata.viewOffsetMs, 30 * _minute);

    // A different cut of the opened title does not lend its position.
    final otherCut = plex.copyWith(durationMs: 150 * _minute);
    final cutLaunch = await harness.play(tester, otherCut);
    expect(cutLaunch.metadata.viewOffsetMs, isNull);
  });

  testWidgets('without a resolver plays the opened item as navigateToVideoPlayer does', (tester) async {
    final harness = await _Harness.pump(tester, resolver: null, storage: storage);

    final launched = await harness.play(tester, plex);

    expect(launched.metadata.globalKey, plex.globalKey);
  });

  testWidgets('waits for the stored priority before reading copies', (tester) async {
    final resolver = _FakeCopyResolver.answering([silo4k, plex]);
    final priority = _SlowPriority();
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage, priority: priority);

    harness.start(plex);
    await tester.pump(const Duration(milliseconds: 100));
    expect(resolver.asked, isEmpty, reason: 'a lookup now would sort by resolution alone');

    priority.loaded.complete();
    await pumpUntil(tester, () => harness.launches.isNotEmpty, describe: () => 'no launch');
    expect(resolver.asked, [plex.globalKey]);
    expect(harness.launches.single.metadata.globalKey, silo4k.globalKey);
  });

  testWidgets('onRefresh runs on return, as navigateToVideoPlayerWithRefresh does', (tester) async {
    final resolver = _FakeCopyResolver.answering([silo4k, plex]);
    final harness = await _Harness.pump(tester, resolver: resolver, storage: storage);
    var refreshed = 0;

    unawaited(playBestCopy(harness.context, metadata: plex, onRefresh: () => refreshed++));
    await pumpUntil(tester, () => refreshed == 1, describe: () => 'refreshed $refreshed times');
    expect(harness.launches.single.metadata.globalKey, silo4k.globalKey);
  });
}

MediaItem _movie(String id, String serverId, String libraryId, {int? viewOffsetMs, List<MediaVersion>? versions}) =>
    testMediaItem(
      id: id,
      backend: serverId == 'plex' ? MediaBackend.plex : MediaBackend.jellyfin,
      kind: MediaKind.movie,
      title: 'The Matrix',
      serverId: serverId,
      libraryId: libraryId,
      durationMs: 136 * _minute,
      viewOffsetMs: viewOffsetMs,
      mediaVersions: versions,
    );

MediaItem _episode(String id, String serverId, String libraryId, String showId) => testMediaItem(
  id: id,
  backend: serverId == 'plex' ? MediaBackend.plex : MediaBackend.jellyfin,
  kind: MediaKind.episode,
  serverId: serverId,
  libraryId: libraryId,
  grandparentId: showId,
  parentIndex: 1,
  index: 2,
  durationMs: 42 * _minute,
);

DownloadedMediaItem _download(MediaItem item, {required int mediaIndex}) => DownloadedMediaItem(
  id: 1,
  serverId: item.serverId!,
  ratingKey: item.id,
  globalKey: item.globalKey,
  type: 'movie',
  status: DownloadStatus.completed.index,
  progress: 100,
  downloadedBytes: 0,
  videoFilePath: '/downloads/${item.id}.mkv',
  retryCount: 0,
  mediaIndex: mediaIndex,
);

/// URLs handed to the external player.
List<String> _mockUrlLauncher() {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final urls = <String>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method != 'launch') return null;
    urls.add((call.arguments as Map)['url'] as String);
    return true;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return urls;
}

/// A detail page under the profile's providers. Every player the launches
/// push is recorded in [launches] and removed before it is ever built.
class _Harness {
  _Harness._(this.clients, this.launches, this._pageKey);

  final Map<String, _Client> clients;
  final List<VideoPlayerScreen> launches;
  final GlobalKey _pageKey;

  BuildContext get context => _pageKey.currentContext!;

  static Future<_Harness> pump(
    WidgetTester tester, {
    required _FakeCopyResolver? resolver,
    required StorageService storage,
    CopyPickStore? picks,
    DownloadProvider? downloads,
    WatchTogetherProvider? watchTogether,
    CopyPriorityProvider? priority,
  }) async {
    final clients = {'plex': _Client('plex', MediaBackend.plex), 'silo': _Client('silo', MediaBackend.jellyfin)};
    final servers = testMultiServer(clients: clients.values.toList());
    final downloadProvider = downloads ?? _Downloads(const {});
    final offlineWatch = _OfflineWatchSync();
    final watchState = _StaleWatchState();
    final copyPriority = priority ?? CopyPriorityProvider(storageService: storage, profileId: 'p1');
    addTearDown(() {
      downloadProvider.dispose();
      offlineWatch.dispose();
      watchState.dispose();
      copyPriority.dispose();
      watchTogether?.dispose();
    });
    final launches = <VideoPlayerScreen>[];
    final pageKey = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
          ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          ChangeNotifierProvider<WatchStateStore>.value(value: watchState),
          ChangeNotifierProvider<CopyPriorityProvider>.value(value: copyPriority),
          Provider<CopyPickStore?>.value(value: picks),
          if (resolver != null) Provider<CopyResolver>.value(value: resolver),
          if (watchTogether != null) ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          navigatorObservers: [_LaunchSpy(launches)],
          home: Scaffold(body: Text('Detail', key: pageKey)),
        ),
      ),
    );
    return _Harness._(clients, launches, pageKey);
  }

  void start(MediaItem item) => unawaited(playBestCopy(context, metadata: item));

  /// Plain Play on [item], to the player it pushes.
  Future<VideoPlayerScreen> play(WidgetTester tester, MediaItem item) async {
    launches.clear();
    start(item);
    await pumpUntil(tester, () => launches.isNotEmpty, describe: () => 'no player launch');
    return launches.single;
  }
}

/// Records the player each video route would build, then removes the route
/// before its first frame, so no player starts.
class _LaunchSpy extends NavigatorObserver {
  _LaunchSpy(this.launches);

  final List<VideoPlayerScreen> launches;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! VideoPlayerRoute) return;
    final nav = navigator!;
    launches.add(route.buildPage(nav.context, kAlwaysCompleteAnimation, kAlwaysCompleteAnimation) as VideoPlayerScreen);
    scheduleMicrotask(() => nav.removeRoute(route));
  }
}

/// Copies best first, as the resolver hands them back.
class _FakeCopyResolver implements CopyResolver {
  _FakeCopyResolver._(this._answer);

  factory _FakeCopyResolver.answering(List<MediaItem> copies) =>
      _FakeCopyResolver._(() => Future.value(ResolvedCopies(copies: copies, aliases: _aliases)));

  factory _FakeCopyResolver.failing(Object error) => _FakeCopyResolver._(() => Future.error(error));

  factory _FakeCopyResolver.pending() {
    final answer = Completer<ResolvedCopies>();
    return _FakeCopyResolver._(() => answer.future).._pending = answer;
  }

  final Future<ResolvedCopies> Function() _answer;
  Completer<ResolvedCopies>? _pending;
  final asked = <String>[];
  AbortController? lastAbort;

  void complete(List<MediaItem> copies) => _pending!.complete(ResolvedCopies(copies: copies, aliases: _aliases));

  @override
  Future<ResolvedCopies> copiesOf(MediaItem item, {AbortController? abort}) {
    asked.add(item.globalKey);
    lastAbort = abort;
    final answer = _answer();
    if (abort == null) return answer;
    return Future.any([answer, abort.trigger.then<ResolvedCopies>((_) => throw StateError('aborted'))]);
  }

  @override
  Future<ResolvedCopies> episodeCopiesOf(MediaItem episode, {AbortController? abort}) =>
      copiesOf(episode, abort: abort);

  @override
  ResolvedCopies? peek(MediaItem item) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The session's watch state still holds Silo 4K's own stale offset: a
/// second overlay of the target's key would put it back.
class _StaleWatchState extends WatchStateStore {
  @override
  MediaItem apply(MediaItem item) => item.id == 'm-4k' ? item.copyWith(viewOffsetMs: 5 * _minute) : item;
}

class _SlowPriority extends ChangeNotifier implements CopyPriorityProvider {
  final loaded = Completer<void>();

  @override
  Future<void> ensureInitialized() => loaded.future;

  @override
  List<String> get priority => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements MediaServerClient {
  _Client(this._serverId, this.backend);

  final String _serverId;
  final externalRequests = <({String id, int mediaIndex, Duration? position})>[];

  @override
  ServerId get serverId => ServerId(_serverId);

  @override
  final MediaBackend backend;

  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    externalRequests.add((id: item.id, mediaIndex: mediaIndex, position: position));
    return ExternalPlaybackTarget(url: 'https://$_serverId/stream/${item.id}');
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Downloads extends ChangeNotifier implements DownloadProvider {
  _Downloads(this.rows);

  final Map<String, DownloadedMediaItem> rows;

  @override
  bool isDownloaded(String globalKey) => rows.containsKey(globalKey);

  @override
  Future<DownloadedMediaItem?> getCompletedDownload(String globalKey) async => rows[globalKey];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A Watch Together room whose file to open is [copy].
class _RoomCopyProvider extends WatchTogetherProvider {
  _RoomCopyProvider(this.copy);

  final WatchCopy copy;

  @override
  owp.Candidate<WatchCopy>? get roomCopy => owp.Candidate(id: 'match', ref: copy, durationMs: 7200000);
}

class _OfflineWatchSync extends ChangeNotifier implements OfflineWatchSyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
