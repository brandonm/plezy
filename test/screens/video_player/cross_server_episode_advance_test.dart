import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/media/play_queue.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/copy_pick_store.dart';
import 'package:plezy/services/copy_resolver.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/episode_navigation_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/external_ids.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/playback_report_fakes.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/pump.dart';
import '../../test_helpers/watch_together_fakes.dart';

/// Next-episode autoplay across servers (copy priority, spec §5): the queue
/// stays on the server the user started from, and each advance plays the
/// best copy of the queue's next episode, wherever it lives.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    await SettingsService.getInstance();
    tmpRoot = await Directory.systemTemp.createTemp('cross_server_episode_advance_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    await DownloadStorageService.instance.initialize(SettingsService.instance);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  /// Mounts the player on [start] with [queue] as the origin series queue,
  /// [origin] and [other] as the profile's servers, and [resolver] /
  /// [pickStore] as the profile's copy services.
  Future<({GlobalKey<VideoPlayerScreenState> key, _AdvancePlayer player, PlaybackStateProvider playbackState})>
  pumpPlayer(
    WidgetTester tester, {
    required MediaItem start,
    MediaItem? queueAnchor,
    required List<MediaItem> queue,
    required _CopyClient origin,
    required _CopyClient other,
    _FakeCopyResolver? resolver,
    CopyPickStore? pickStore,
  }) async {
    final multi = testMultiServer(clients: [origin, other]);
    final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
    final accountPreferences = AccountPreferencesController();
    final playbackState = PlaybackStateProvider();
    // The series queue the origin server publishes for its show.
    playbackState.setPlaybackFromLocalQueue(
      LocalPlayQueue(items: queue, currentIndex: queue.indexOf(queueAnchor ?? start)),
      contextKey: (queueAnchor ?? start).grandparentId,
    );
    final initializationHold = Completer<void>();
    Future<void> holdInitialization() => initializationHold.future;
    PlaybackCoordinator.instance.registerMusicSession(stopAndDispose: holdInitialization);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PlaybackCoordinator.instance.unregisterMusicSession(holdInitialization);
      if (!initializationHold.isCompleted) initializationHold.complete();
      await tester.pump();
      offlineWatch.dispose();
      accountPreferences.dispose();
      playbackState.dispose();
    });
    final key = GlobalKey<VideoPlayerScreenState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
          ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPreferences),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: WatchTogetherProvider()),
          Provider<AppDatabase>.value(value: db),
          ChangeNotifierProvider(create: (_) => CompanionRemoteProvider()),
          if (resolver != null) Provider<CopyResolver>.value(value: resolver),
          Provider<CopyPickStore?>.value(value: pickStore),
        ],
        child: MaterialApp(
          home: VideoPlayerScreen(
            key: key,
            metadata: start,
            queueAnchor: queueAnchor,
            selectedQualityPreset: TranscodeQualityPreset.original,
          ),
        ),
      ),
    );
    await tester.pump();
    final fakePlayer = _AdvancePlayer();
    addTearDown(fakePlayer.dispose);
    key.currentState!.player = fakePlayer;
    // The held startup resolves its own source; only what follows counts.
    await tester.pump();
    origin.opened.clear();
    other.opened.clear();
    return (key: key, player: fakePlayer, playbackState: playbackState);
  }

  /// Runs [action] to its end, yielding to the real event loop for the
  /// database work an in-place reload does.
  Future<void> settle(WidgetTester tester, Future<void> Function() action) async {
    var done = false;
    final future = action().whenComplete(() => done = true);
    for (var i = 0; i < 400 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!done) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
    }
    expect(done, isTrue, reason: 'the action must settle');
    await future;
  }

  /// Waits for the adjacency load an in-place reload starts in the background.
  Future<void> nextLoaded(WidgetTester tester, VideoPlayerScreenState state, String? expectedId) => pumpUntil(
    tester,
    () => state.debugNextEpisodeForTesting?.id == expectedId,
    describe: () => 'next=${state.debugNextEpisodeForTesting?.id}',
  );

  testWidgets('two advances after a cross-server switch both find next from the origin queue', (tester) async {
    final origin = _CopyClient('plex-1', MediaBackend.plex);
    final silo = _CopyClient('silo', MediaBackend.jellyfin);
    final e1 = _episode('e1', 'plex-1', 1);
    final e2 = _episode('e2', 'plex-1', 2);
    final e3 = _episode('e3', 'plex-1', 3);
    final e4 = _episode('e4', 'plex-1', 4);
    final siloE2 = _episode('s-e2', 'silo', 2, show: 'silo-show', backend: MediaBackend.jellyfin);
    final siloE3 = _episode('s-e3', 'silo', 3, show: 'silo-show', backend: MediaBackend.jellyfin);
    final resolver = _FakeCopyResolver({
      e2.globalKey: [siloE2],
      e3.globalKey: [siloE3],
    });

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screen = await pumpPlayer(
          tester,
          start: e1,
          queue: [e1, e2, e3, e4],
          origin: origin,
          other: silo,
          resolver: resolver,
        );
        final state = screen.key.currentState!;

        await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
        expect(state.debugNextEpisodeForTesting, same(e2));
        await tester.pump();
        expect(resolver.asked, [e2.globalKey], reason: 'committing next starts its copy lookup');

        // First advance: Silo holds the best copy of E2.
        await settle(tester, state.debugPlayNextForTesting);
        expect(silo.opened.map((o) => o.metadata.id), ['s-e2']);
        expect(origin.opened, isEmpty);
        expect(state.debugCurrentMetadataForTesting.globalKey, siloE2.globalKey);
        expect(screen.playbackState.currentQueueItem, same(e2), reason: 'the queue cursor stays on the origin');
        await nextLoaded(tester, state, 'e3');
        expect(state.debugNextEpisodeForTesting, same(e3));
        expect(screen.playbackState.shuffleContextKey, 'show-1', reason: 'the origin queue is untouched');

        // A load that names no item (the EOF retry, startup) asks the origin
        // queue too, not Silo's copy.
        state.debugCommitAdjacentEpisodesForTesting(const AdjacentEpisodes.failed());
        expect(state.debugNextEpisodeForTesting, isNull);
        await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
        expect(state.debugNextEpisodeForTesting, same(e3));

        // Silo's copy renders, so its session reports.
        await state.debugWirePlayerStreamsForTesting();
        screen.player.emitPlaying(true);
        screen.player.emitPlaybackRestart();
        await tester.pump();

        // Second advance: still found from the origin queue, played from Silo.
        await settle(tester, state.debugPlayNextForTesting);
        expect(silo.opened.map((o) => o.metadata.id), ['s-e2', 's-e3']);
        expect(
          silo.reports.where((r) => r.kind == PlaybackReportKind.stopped).map((r) => r.itemId),
          contains('s-e2'),
          reason: "the copy's progress goes to the copy's server",
        );
        expect(origin.reports.map((r) => r.itemId), isNot(contains('s-e2')));
        expect(screen.playbackState.currentQueueItem, same(e3));
        await nextLoaded(tester, state, 'e4');

        // Third: Silo lacks E4, so the origin's own copy plays.
        await settle(tester, state.debugPlayNextForTesting);
        expect(origin.opened.map((o) => o.metadata.id), ['e4']);
        expect(state.debugCurrentMetadataForTesting.globalKey, e4.globalKey);
        expect(screen.playbackState.currentQueueItem, same(e4));
        expect(resolver.asked.toSet(), {e2.globalKey, e3.globalKey, e4.globalKey}, reason: 'each next is looked up');
      },
    );
  });

  testWidgets('lookup unanswered at advance plays the same-server next episode', (tester) async {
    final origin = _CopyClient('plex-1', MediaBackend.plex);
    final silo = _CopyClient('silo', MediaBackend.jellyfin);
    final e1 = _episode('e1', 'plex-1', 1);
    final e2 = _episode('e2', 'plex-1', 2);
    final e3 = _episode('e3', 'plex-1', 3);
    final siloE2 = _episode('s-e2', 'silo', 2, show: 'silo-show', backend: MediaBackend.jellyfin);
    final resolver = _FakeCopyResolver({
      e2.globalKey: [siloE2],
    }, answers: false);

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screen = await pumpPlayer(
          tester,
          start: e1,
          queue: [e1, e2, e3],
          origin: origin,
          other: silo,
          resolver: resolver,
        );
        final state = screen.key.currentState!;
        await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
        await tester.pump();
        expect(resolver.asked, [e2.globalKey]);

        await settle(tester, state.debugPlayNextForTesting);
        expect(origin.opened.map((o) => o.metadata.id), ['e2'], reason: 'the lookup has not answered: play next');
        expect(silo.opened, isEmpty);
        expect(screen.playbackState.currentQueueItem, same(e2));
        await nextLoaded(tester, state, 'e3');
      },
    );
  });

  testWidgets('multi-episode Plex file: anchor keeps playedPartId so the sibling is skipped', (tester) async {
    // E1 and E2 are one file on the origin (S01E01-E02.mkv); E1 also has a
    // second, standalone version. The copy that plays E1 lives on another
    // Plex server, where its part id happens to be 501 - which on the origin
    // names E1's standalone file. Part ids are per server, so the queue must
    // ask with the origin's own part, not the copy's.
    const multiFile = '/tv/Show/S01E01-E02.mkv';
    final origin = _CopyClient('plex-1', MediaBackend.plex);
    final other = _CopyClient('plex-2', MediaBackend.plex, partId: 501);
    final e0 = _episode('e0', 'plex-1', 0, file: '/tv/Show/S01E00.mkv', partId: '400');
    final e1 = _episode(
      'e1',
      'plex-1',
      1,
      versions: [_version('v-multi', '500', multiFile), _version('v-alt', '501', '/tv/Show/S01E01.alt.mkv')],
    );
    final e2 = _episode('e2', 'plex-1', 2, file: multiFile, partId: '600');
    final e3 = _episode('e3', 'plex-1', 3, file: '/tv/Show/S01E03.mkv', partId: '700');
    final otherE1 = _episode('o-e1', 'plex-2', 1, show: 'other-show');
    final resolver = _FakeCopyResolver({
      e1.globalKey: [otherE1],
    });

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screen = await pumpPlayer(
          tester,
          start: e0,
          queue: [e0, e1, e2, e3],
          origin: origin,
          other: other,
          resolver: resolver,
        );
        final state = screen.key.currentState!;
        await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
        expect(state.debugNextEpisodeForTesting, same(e1));
        await tester.pump();

        await settle(tester, state.debugPlayNextForTesting);
        expect(other.opened.map((o) => o.metadata.id), ['o-e1']);
        // E2 is the rest of the file E1 opened: next skips it.
        await nextLoaded(tester, state, 'e3');
      },
    );
  });

  testWidgets('version signature is dropped when the server changes', (tester) async {
    final origin = _CopyClient('plex-1', MediaBackend.plex, versions: _twoVersions, selectedIndex: 1);
    final silo = _CopyClient('silo', MediaBackend.jellyfin, versions: _twoVersions, selectedIndex: 1);
    final e0 = _episode('e0', 'plex-1', 0);
    final e1 = _episode('e1', 'plex-1', 1);
    final e2 = _episode('e2', 'plex-1', 2);
    final e3 = _episode('e3', 'plex-1', 3);
    final siloE2 = _episode('s-e2', 'silo', 2, show: 'silo-show', backend: MediaBackend.jellyfin);
    final siloE3 = _episode('s-e3', 'silo', 3, show: 'silo-show', backend: MediaBackend.jellyfin);
    final resolver = _FakeCopyResolver({
      e2.globalKey: [siloE2],
      e3.globalKey: [siloE3],
    });
    final fourK = _twoVersions[1].signature;

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screen = await pumpPlayer(
          tester,
          start: e0,
          queue: [e0, e1, e2, e3],
          origin: origin,
          other: silo,
          resolver: resolver,
        );
        final state = screen.key.currentState!;
        await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
        // E1 opens on the origin in its 4K version (no copies looked up).
        await settle(tester, state.debugPlayNextForTesting);
        expect(origin.opened.single.metadata.id, 'e1');
        await nextLoaded(tester, state, 'e2');
        await tester.pump();

        // Plex -> Silo: the 4K signature means nothing on Silo's version list.
        await settle(tester, state.debugPlayNextForTesting);
        final toSilo = silo.opened.single;
        expect(toSilo.metadata.id, 's-e2');
        expect(toSilo.preferredVersionSignature, isNull);
        expect(toSilo.selectedMediaIndex, 0);
        await nextLoaded(tester, state, 'e3');
        await tester.pump();

        // Silo -> Silo: same server, so today's carry applies.
        await settle(tester, state.debugPlayNextForTesting);
        final withinSilo = silo.opened.last;
        expect(withinSilo.metadata.id, 's-e3');
        expect(withinSilo.preferredVersionSignature, fourK);
        expect(withinSilo.selectedMediaIndex, 1);
      },
    );
  });

  for (final pickFound in [true, false]) {
    testWidgets(
      pickFound
          ? "a remembered pick's signature carries to the copy it chose on another server"
          : 'a remembered pick whose copy is missing carries no signature to the ranked copy',
      (tester) async {
        // Shared preferences answer on the real event loop.
        final pickStore = CopyPickStore((await tester.runAsync(StorageService.getInstance))!, 'profile-1');
        final origin = _CopyClient('plex-1', MediaBackend.plex);
        final silo = _CopyClient('silo', MediaBackend.jellyfin);
        final e1 = _episode('e1', 'plex-1', 1);
        final e2 = _episode('e2', 'plex-1', 2);
        final siloHdE2 = _episode('hd-e2', 'silo', 2, show: 'silo-hd', backend: MediaBackend.jellyfin, library: 'hd');
        final silo4kE2 = _episode('4k-e2', 'silo', 2, show: 'silo-4k', backend: MediaBackend.jellyfin, library: '4k');
        final resolver = _FakeCopyResolver({
          e2.globalKey: [silo4kE2, if (pickFound) siloHdE2],
        });
        // The user picked Silo HD's 1080p version for the show.
        await tester.runAsync(
          () => pickStore.write(
            _FakeCopyResolver.aliases,
            const CopyPick(key: 'silo:silo-hd', lib: 'silo:hd', sig: '1080:h264:mkv', at: 1),
          ),
        );

        await withMockPlayerChannels(
          methodChannelName: 'com.plezy/mpv_player',
          eventChannelName: 'com.plezy/mpv_player/events',
          testBody: () async {
            final screen = await pumpPlayer(
              tester,
              start: e1,
              queue: [e1, e2],
              origin: origin,
              other: silo,
              resolver: resolver,
              pickStore: pickStore,
            );
            final state = screen.key.currentState!;
            await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
            await tester.pump();

            await settle(tester, state.debugPlayNextForTesting);
            final opened = silo.opened.single;
            if (pickFound) {
              expect(opened.metadata.id, 'hd-e2', reason: 'the pick beats the ranking');
              expect(opened.preferredVersionSignature, '1080:h264:mkv');
            } else {
              expect(opened.metadata.id, '4k-e2', reason: 'the ranking chooses when the picked copy is gone');
              expect(opened.preferredVersionSignature, isNull, reason: "the pick's version belongs to another copy");
            }
          },
        );
      },
    );
  }

  testWidgets('a screen opened on a copy with its queue anchor keeps the origin queue', (tester) async {
    // The screen-replacement path (_replaceScreenWithPlayer) hands the new
    // screen the copy to play and the origin queue's entry.
    final origin = _CopyClient('plex-1', MediaBackend.plex);
    final silo = _CopyClient('silo', MediaBackend.jellyfin);
    final e1 = _episode('e1', 'plex-1', 1);
    final e2 = _episode('e2', 'plex-1', 2);
    final e3 = _episode('e3', 'plex-1', 3);
    final siloE2 = _episode('s-e2', 'silo', 2, show: 'silo-show', backend: MediaBackend.jellyfin);

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screen = await pumpPlayer(
          tester,
          start: siloE2,
          queueAnchor: e2,
          queue: [e1, e2, e3],
          origin: origin,
          other: silo,
        );
        final state = screen.key.currentState!;
        expect(screen.playbackState.isQueueActive, isTrue, reason: 'the copy is not a stray item: keep its queue');
        expect(screen.playbackState.currentQueueItem, same(e2));
        await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
        expect(state.debugNextEpisodeForTesting, same(e3));
      },
    );
  });

  testWidgets('without a copy resolver the next episode plays from the queue as today', (tester) async {
    final origin = _CopyClient('plex-1', MediaBackend.plex);
    final silo = _CopyClient('silo', MediaBackend.jellyfin);
    final e1 = _episode('e1', 'plex-1', 1);
    final e2 = _episode('e2', 'plex-1', 2);
    final e3 = _episode('e3', 'plex-1', 3);

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screen = await pumpPlayer(tester, start: e1, queue: [e1, e2, e3], origin: origin, other: silo);
        final state = screen.key.currentState!;
        await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
        await settle(tester, state.debugPlayNextForTesting);
        expect(origin.opened.map((o) => o.metadata.id), ['e2']);
        expect(silo.opened, isEmpty);
        await nextLoaded(tester, state, 'e3');
      },
    );
  });

  for (final shuffled in [true, false]) {
    testWidgets(shuffled ? 'a shuffled queue is not retargeted' : 'a playlist queue is not retargeted', (tester) async {
      final origin = _CopyClient('plex-1', MediaBackend.plex);
      final silo = _CopyClient('silo', MediaBackend.jellyfin);
      final e1 = _episode('e1', 'plex-1', 1);
      final e2 = _episode('e2', 'plex-1', 2);
      final siloE2 = _episode('s-e2', 'silo', 2, show: 'silo-show', backend: MediaBackend.jellyfin);
      final resolver = _FakeCopyResolver({
        e2.globalKey: [siloE2],
      });

      await withMockPlayerChannels(
        methodChannelName: 'com.plezy/mpv_player',
        eventChannelName: 'com.plezy/mpv_player/events',
        testBody: () async {
          final screen = await pumpPlayer(
            tester,
            start: e1,
            queue: [e1, e2],
            origin: origin,
            other: silo,
            resolver: resolver,
          );
          screen.playbackState.setPlaybackFromLocalQueue(
            LocalPlayQueue(items: [e1, e2], currentIndex: 0, shuffled: shuffled),
            contextKey: shuffled ? 'show-1' : 'playlist-9',
          );
          final state = screen.key.currentState!;
          await settle(tester, state.debugLoadAdjacentEpisodesForTesting);
          await tester.pump();
          expect(resolver.asked, isEmpty, reason: 'shuffle and playlists keep their own items');
          resolver.answered.add(e2.globalKey);

          await settle(tester, state.debugPlayNextForTesting);
          expect(origin.opened.map((o) => o.metadata.id), ['e2']);
          expect(silo.opened, isEmpty);
        },
      );
    });
  }
}

const _twoVersions = [
  MediaVersion(id: 'hd', videoResolution: '1080', videoCodec: 'h264', container: 'mkv'),
  MediaVersion(id: 'uhd', videoResolution: '4k', videoCodec: 'hevc', container: 'mkv'),
];

MediaVersion _version(String id, String partId, String file) => MediaVersion(
  id: id,
  videoResolution: '1080',
  videoCodec: 'h264',
  container: 'mkv',
  parts: [MediaPart(id: partId, file: file)],
);

MediaItem _episode(
  String id,
  String serverId,
  int index, {
  String show = 'show-1',
  MediaBackend backend = MediaBackend.plex,
  String library = 'tv',
  String? file,
  String? partId,
  List<MediaVersion>? versions,
}) => testMediaItem(
  id: id,
  backend: backend,
  kind: MediaKind.episode,
  title: 'Episode $index',
  serverId: serverId,
  grandparentId: show,
  parentIndex: 1,
  index: index,
  durationMs: 40 * 60 * 1000,
  libraryId: library,
  mediaVersions: versions ?? (file == null ? null : [_version('v-$id', partId ?? 'p-$id', file)]),
);

/// A server holding some of the episodes; records what the player opened on
/// it.
class _CopyClient with PlaybackReportRecorder implements MediaServerClient {
  _CopyClient(this._serverId, this.backend, {this.partId, this.versions = const [], this.selectedIndex = 0});

  final String _serverId;
  final int? partId;
  final List<MediaVersion> versions;
  final int selectedIndex;
  final opened = <PlaybackInitializationOptions>[];
  final reports = <PlaybackReportCall>[];

  @override
  final MediaBackend backend;
  @override
  ServerId get serverId => ServerId(_serverId);
  @override
  String get serverName => _serverId;
  @override
  ServerCapabilities get capabilities =>
      backend == MediaBackend.plex ? ServerCapabilities.plex : ServerCapabilities.jellyfin;
  @override
  double get watchedThreshold => 0.9;
  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async => const ExternalIds();
  @override
  bool get marksWatchedOnPlaybackStopped => true;
  @override
  Map<String, String> get streamHeaders => const {};

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    opened.add(options);
    final url = 'https://$_serverId.invalid/${options.metadata.id}';
    return PlaybackInitializationResult(
      availableVersions: versions,
      videoUrl: url,
      selectedMediaIndex: versions.isEmpty ? 0 : selectedIndex,
      mediaInfo: MediaSourceInfo(
        videoUrl: url,
        audioTracks: const [],
        subtitleTracks: const [],
        chapters: const [],
        partId: partId,
      ),
    );
  }

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async => reports.add(call);

  @override
  Future<MediaItem?> fetchItem(String id) async => null;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Copies per origin episode, best first; [peek] answers only once
/// [episodeCopiesOf] did, and never when [answers] is false.
class _FakeCopyResolver implements CopyResolver {
  _FakeCopyResolver(this._copies, {this.answers = true});

  static const aliases = {'show|tvdb:81189'};

  final Map<String, List<MediaItem>> _copies;
  final bool answers;
  final asked = <String>[];
  final answered = <String>{};

  ResolvedCopies _view(MediaItem episode) =>
      ResolvedCopies(copies: [...?_copies[episode.globalKey], episode], aliases: aliases);

  @override
  Future<ResolvedCopies> episodeCopiesOf(MediaItem episode, {AbortController? abort}) {
    asked.add(episode.globalKey);
    if (!answers) return Completer<ResolvedCopies>().future;
    answered.add(episode.globalKey);
    return Future.value(_view(episode));
  }

  @override
  ResolvedCopies? peek(MediaItem item) => answered.contains(item.globalKey) ? _view(item) : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AdvancePlayer extends FakeSyncPlayer {
  _AdvancePlayer()
    : super(playing: true, position: const Duration(seconds: 121), duration: const Duration(minutes: 40), rate: 1.0);

  @override
  String get playerType => 'mpv';

  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => false;

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<String?> getProperty(String name) async => null;

  @override
  Future<void> updateFrame() async {}

  @override
  Future<void> awaitDisplayModeSwitch({int extraDelayMs = 0}) async {}

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> stop() async {
    setPosition(Duration.zero);
    emitPlaying(false);
  }

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    setPosition(media.start ?? Duration.zero);
    setCompleted(false);
    emitPlaying(play);
    emitFileStarted();
    emitPlaybackRestart();
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {}
}
