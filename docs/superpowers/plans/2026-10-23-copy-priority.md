# Copy Priority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rank libraries per device and make plain Play start the best-ranked copy of a movie or episode across Plex, Jellyfin and Silo, resuming from the furthest progress across copies.

**Architecture:** Pure ranking/selection functions in `lib/media/`, a profile-scoped `CopyResolver` service over the existing cross-server title lookup, a per-profile priority list and copy-pick store in `StorageService`, and one `playBestCopy` wrapper that the plain-Play call sites switch to. The player keeps its episode queue anchored to the origin server and swaps in the best copy only at each advance.

**Tech Stack:** Flutter / Dart, `provider`, `flutter_test`, `fake_async`, slang i18n.

**Spec:** `docs/superpowers/specs/2026-10-23-copy-priority-design.md` (revision 2 + per-device decision, commit `2bdd75ce5`). Read it before any task; section numbers below (§N) refer to it.

## Global Constraints

- Branch `feat/copy-priority` from `docs/copy-priority-spec`. Commit with `git-as-claude commit`, never plain `git commit`; never write `user.*` into `.git/config`. Do not push: `origin` is upstream GitHub.
- `dart format` at `page_width: 120`; `flutter analyze` clean; tests via `scripts/run_tests.sh <path>`.
- New user-facing strings go in `lib/i18n/en.i18n.json` only; run `scripts/codegen.sh` after editing it.
- Ranking and picks are per device; neither key joins settings export/import (`settings_export_service.dart`).
- Unchanged paths (§Out of scope): playlists, play queues, collections, shuffle, agent/remote commands, Watch Together, trailers, explicit external-player launches, "Play from beginning", offline mode, Live TV.
- Pinned values: Play wait cap **2 s**; cache TTL **5 minutes**; episode duration-match tolerance **10%**; resume duration tolerance **5%**; copy-pick cap **500** records, oldest-first eviction.
- Any resolver failure, timeout or empty result → play the opened item exactly as today.
- Every fix is proved by breaking it and watching its test fail before restoring it.

## Review Focus

1. **Plex multi-episode file** (one file spanning S01E01–E02) played from a cross-server copy: next must still skip the sibling entry, not replay the same file. → test in Task 7.
2. **Specials (season 0)** on one server and not another: S00E03 must match only S00E03 and never fall through to S01E03. → test in Task 4.
3. **One server holding the title in two libraries** (Silo Movies 4K and Movies 4K Remux): both copies survive dedup and rank by the list. → test in Task 6.
4. **Priority list naming a library that no longer exists** (deleted or server removed outside the app): ignored at ranking time and absent from the settings screen, no crash. → tests in Tasks 2 and 10.
5. **The lookup returns a stale object for the opened item itself:** the picker shows it once, using the opened (fresh) object. → test in Task 6.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `lib/services/storage_service.dart` (modify) | Persist the priority list and copy-pick records per profile; server-removal cleanup |
| `lib/providers/copy_priority_provider.dart` (create) | Profile-scoped `ChangeNotifier` over the priority list |
| `lib/media/media_item_merge.dart` (modify) | `compareCopiesByPriority`; comparator parameter on `mergeLibraryCopies` |
| `lib/media/title_copies.dart` (modify) | Public `findShowCopies`, `episodesOf`; stamp-preserving `_withVersions` |
| `lib/services/data_aggregation_service.dart` (modify) | `findShowCopiesAcrossServers` |
| `lib/media/copy_selection.dart` (create) | Pure functions: episode stamp and match, resume offset, target choice |
| `lib/services/copy_pick_store.dart` (create) | Alias-keyed remembered picks over `StorageService` |
| `lib/services/copy_resolver.dart` (create) | Lookups, cache, scope, online filtering, watch-state overlay |
| `lib/navigation/profile_session_screen.dart` (modify) | Provide `CopyPriorityProvider`, `CopyPickStore`, `CopyResolver` per profile |
| `lib/screens/video_player/parts/episode_queue.dart`, `episode_navigation.dart`, `lib/screens/video_player_screen.dart` (modify) | `_queueAnchor`; best copy at advance |
| `lib/utils/video_player_navigation.dart` (modify) | `playBestCopy` |
| Call-site files (Task 8) | Switch plain Play to `playBestCopy` |
| `lib/screens/media_detail_screen.dart`, `lib/screens/media_detail/action_buttons.dart`, `lib/widgets/copy_version_picker.dart` (create) | Playback target, label, grouped picker, reset row, "Also in" |
| `lib/screens/settings/copy_priority_screen.dart` (create), `playback_settings_screen.dart` (modify) | Reorderable priority list |
| `lib/services/catalog/catalog_library_matcher.dart`, `lib/screens/catalog_item_detail_screen.dart` (modify) | Ranked catalog copies, re-sort on change |

---

### Task 1: Priority list storage and provider

**Files:**
- Modify: `lib/services/storage_service.dart` (new key beside `_keyLibraryOrder` at `:19`; list at `:37`; cleanup at `:403-428`)
- Create: `lib/providers/copy_priority_provider.dart`
- Modify: `lib/navigation/profile_session_screen.dart:220` (provide it next to `HiddenLibrariesProvider`)
- Test: `test/services/storage_service_copy_priority_test.dart`, `test/providers/copy_priority_provider_test.dart`

**Interfaces:**
- Produces: `StorageService.getCopyPriorityForProfile(String profileId) → List<String>`; `StorageService.saveCopyPriorityForProfile(String profileId, List<String> libraryKeys) → Future<void>`; `CopyPriorityProvider({StorageService? storageService, String? profileId})` with `List<String> get priority`, `Future<void> ensureInitialized()`, `Future<void> setPriority(List<String> libraryKeys)`.

- [ ] **Step 1: Write the failing tests**

```dart
test('copy priority round-trips per profile', () async {
  await storage.saveCopyPriorityForProfile('p1', ['s1:10', 's2:20']);
  expect(storage.getCopyPriorityForProfile('p1'), ['s1:10', 's2:20']);
  expect(storage.getCopyPriorityForProfile('p2'), isEmpty);
});
test('server removal drops that server from copy priority (profile path)', () async {
  await storage.saveCopyPriorityForProfile('p1', ['s1:10', 's2:20', 's1:11']);
  await storage.clearLibraryPreferencesForServer(ServerId('s1'), profileId: 'p1');
  expect(storage.getCopyPriorityForProfile('p1'), ['s2:20']);
});
test('server removal drops that server from copy priority (everywhere path)', () async { /* same via clearLibraryPreferencesForServerEverywhere, two profiles */ });
test('clearLibraryPreferences clears copy priority', () async { /* … */ });
// provider
test('setPriority persists and notifies', () async { /* listener called once; storage holds list */ });
```

Use the `SharedPreferences` setup from `test/test_helpers/prefs.dart`.

- [ ] **Step 2: Run** `scripts/run_tests.sh test/services/storage_service_copy_priority_test.dart test/providers/copy_priority_provider_test.dart`. Expected: FAIL, methods undefined.
- [ ] **Step 3: Implement.** Key `copy_priority`, stored with `_setStringList` / `_getStringList` under `_userPrefixForProfileId(profileId)`. Add it to `_libraryPreferenceKeys`, to `_clearLibraryPreferencesForServerPrefix` (`_filterServerEntriesFromStringList`) and to `clearLibraryPreferencesForServerEverywhere` (`_filterServerEntriesFromAllStringListKeys`). The provider mirrors `HiddenLibrariesProvider` (eager `_initFuture`, `DisposableChangeNotifierMixin`, `safeNotifyListeners`). Wire it as a lazy `ChangeNotifierProvider` with `profileId: activeId`.
- [ ] **Step 4: Run the same command.** Expected: PASS. Break the everywhere-path line, see that test fail, then restore it.
- [ ] **Step 5: Commit** `feat(copies): store a per-profile library priority list`.

### Task 2: Priority comparator

**Files:**
- Modify: `lib/media/media_item_merge.dart` (beside `compareLibraryCopies`, `:59`; `mergeLibraryCopies`, `:113`)
- Test: `test/media/media_item_merge_test.dart` (extend)

**Interfaces:**
- Produces: `Comparator<MediaItem> compareCopiesByPriority(List<String> priority)`; `List<MediaItem> mergeLibraryCopies(Iterable<MediaItem> current, Iterable<MediaItem> additions, {Comparator<MediaItem> compare = compareLibraryCopies})`.

- [ ] **Step 1: Write the failing tests** using `testMediaItem` with `serverId`, `libraryId`, `mediaVersions` (heights):

```dart
test('ranked libraries order by list index', () {
  final cmp = compareCopiesByPriority(['silo:remux', 'silo:4k', 'plex:movies']);
  expect(sorted([plexMovies1080, silo4k2160, siloRemux2160], cmp), [siloRemux2160, silo4k2160, plexMovies1080]);
});
test('any ranked copy beats any unranked copy', () { /* ranked 720p beats unranked 2160p */ });
test('unranked copies order by best resolution', () { /* … */ });
test('copy without libraryId is unranked', () { /* … */ });
test('ties fall through to compareLibraryCopies and are total', () { /* identical keys → globalKey order; sort twice gives same list */ });
test('a priority entry naming no present library is ignored', () { /* list ['gone:1', 'silo:4k'] → silo:4k still ranks first */ });
test('mergeLibraryCopies uses the supplied comparator', () { /* … */ });
```

- [ ] **Step 2: Run** `scripts/run_tests.sh test/media/media_item_merge_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Build `Map<String,int>` index once per comparator. Library key = `buildGlobalKey(ServerId(item.serverId!), item.libraryId!)` when both are non-null, else unranked.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(copies): rank library copies by a priority list`.

### Task 3: Show-level lookup, public episode lookup, stamp-preserving enrichment

**Files:**
- Modify: `lib/media/title_copies.dart` (`_titleItems` `:95`, `_episodesOf` `:145`, `_withVersions` `:181`)
- Modify: `lib/services/data_aggregation_service.dart` (beside `findTitleCopiesAcrossServers`, `:970`)
- Test: `test/watch_together/title_copies_test.dart` (extend; reuse its `_Library` fake)

**Interfaces:**
- Produces, on `TitleCopiesLookup`: `Future<List<MediaItem>> findShowCopies(TitleQuery query, {AbortController? abort})`, which takes `showTitle/showYear/showIds/showPlexGuid` from an episode query and returns shows; `Future<List<MediaItem>> episodesOf(MediaItem show, {required int season, required int episode, AbortController? abort})`, the renamed `_episodesOf` with unchanged behavior. On `DataAggregationService`: `Future<LibraryLookupResult> findShowCopiesAcrossServers(TitleQuery query, {AbortController? abort})`, with the same fan-out, deadline and `mergeLibraryCopies` as its sibling.

- [ ] **Step 1: Write the failing tests**

```dart
test('findShowCopies returns shows, not episodes', () async { /* byIds[show] → that show; no fetchChildren */ });
test('_withVersions keeps a library stamp the fetched item lacks', () async {
  // byIds[movie] → movie(libraryId: 'lib4k', libraryTitle: 'Movies 4K', no versions)
  // full[id] → same id, versions present, libraryId null
  final copies = await lib.findTitleCopies(TitleQuery.movie(title: 'X', ids: ids));
  expect(copies.single.libraryId, 'lib4k');
  expect(copies.single.mediaVersions, isNotEmpty);
});
test('findShowCopiesAcrossServers reports per-server accounting', () async { /* one failing server lands in failedServerIds */ });
```

- [ ] **Step 2: Run** `scripts/run_tests.sh test/watch_together/title_copies_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** In `_withVersions`, use `mergeFetchedMediaItem(fetched: f, fallbackServerId: serverId, existing: item)`. Make `findTitleCopies` call `findShowCopies` for its show half, so there's one show path.
- [ ] **Step 4: Run** the file plus `test/services/data_aggregation_bridge_test.dart`. Expected: PASS, with existing tests unchanged.
- [ ] **Step 5: Commit** `feat(copies): show-level copy lookup and stamp-preserving enrichment`.

### Task 4: Pure selection functions

**Files:**
- Create: `lib/media/copy_selection.dart`
- Test: `test/media/copy_selection_test.dart`

**Interfaces:**
- Produces:
  - `MediaItem stampFromShow(MediaItem episode, MediaItem showCopy)`: copies `libraryId` and `libraryTitle` from the show onto the episode unless the episode already has a `libraryId`.
  - `bool acceptEpisodeCopy({required MediaItem opened, required ExternalIds openedIds, required MediaItem candidate, required ExternalIds candidateIds})`.
  - `int? furthestResumeOffsetMs(MediaItem target, Iterable<MediaItem> copies)`.
  - `typedef CopyPickRef = ({String key, String lib, String? sig});` (declared here; Task 5's `CopyPick` exposes it as `ref`).
  - `MediaItem chooseTarget(List<MediaItem> rankedCopies, CopyPickRef? pick)`.

- [ ] **Step 1: Write the failing tests**

```dart
// acceptEpisodeCopy (§2 Episode matching)
test('agreeing episode ids accept', ...);
test('one contradicting id rejects even with agreeing others', ...);
test('no ids on either side: durations within 10% accept, outside reject', () {
  expect(accept(opened(durationMs: 1_000_000), cand(durationMs: 1_099_000)), isTrue);
  expect(accept(opened(durationMs: 1_000_000), cand(durationMs: 1_101_000)), isFalse);
});
test('no ids and an unknown duration rejects', ...);
test('season 0 never matches season 1 of the same number', ...); // Review Focus 2
// stampFromShow
test('episode inherits the show copy library stamp', ...);
test('an existing episode stamp is kept', ...);
// furthestResumeOffsetMs (§3 step 4)
test('furthest in-progress copy wins', ...);
test('watched copy with a residual offset is ignored', () { /* viewCount 1, viewOffsetMs 600000 → ignored */ });
test('copy whose duration differs by more than 5% is ignored', ...);
test('no in-progress copy returns null', ...);
// chooseTarget
test('pick by key beats ranking', ...);
test('pick by lib is used when key is absent', ...);
test('pick naming no present copy falls back to first', ...);
test('no pick returns first', ...);
```

- [ ] **Step 2: Run** `scripts/run_tests.sh test/media/copy_selection_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Season check: `(candidate.parentIndex ?? -1) == (opened.parentIndex ?? -1)` and the same for `index`, required before the ID and duration rules. Use `contradicts` from `title_copies.dart:209`. "Agree" means some shared provider has an equal value. Watched means `isWatched`, in-progress means `hasActiveProgress`, and both must hold as `!isWatched && hasActiveProgress`.
- [ ] **Step 4: Run.** Expected: PASS. Break the `!isWatched` guard, watch the residual-offset test fail, then restore it.
- [ ] **Step 5: Commit** `feat(copies): pure episode matching, resume and target selection`.

### Task 5: Copy-pick store

**Files:**
- Modify: `lib/services/storage_service.dart` (raw JSON get/set for key `copy_picks` per profile; cleanup hook in both server paths)
- Create: `lib/services/copy_pick_store.dart`
- Test: `test/services/copy_pick_store_test.dart`

**Interfaces:**
- Produces: `class CopyPick { final String key; final String lib; final String? sig; final int at; CopyPickRef get ref; }`; `class CopyPickStore { CopyPickStore(StorageService storage, String profileId); CopyPick? read(Set<String> aliases); Future<void> write(Set<String> aliases, CopyPick pick); Future<void> clear(Set<String> aliases); }`; `Set<String> copyAliases(MediaKind kind, Iterable<ExternalIds> ids)`, which returns e.g. `{'show|tvdb:81189', 'show|tmdb:1399'}`. Storage: `Map<String /*recordId*/, CopyPick>` plus `Map<String /*alias*/, String /*recordId*/>` in one JSON value.

- [ ] **Step 1: Write the failing tests**

```dart
test('written under all aliases and read from any one', () async {
  await store.write({'show|tmdb:1', 'show|tvdb:2'}, pick);
  expect(store.read({'show|tvdb:2'})?.lib, pick.lib);
});
test('newest record wins when aliases point at different records', ...);
test('copyAliases skips missing ids and prefixes kind', ...);
test('cap 500 evicts oldest', ...);
test('server removal deletes records whose lib names it (profile and everywhere)', ...);
test('clear removes the record and all its aliases', ...);
```

- [ ] **Step 2: Run** `scripts/run_tests.sh test/services/copy_pick_store_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Add `StorageService.getCopyPicksJsonForProfile` / `saveCopyPicksJsonForProfile`. Add a `_dropCopyPicksForServer(prefix, serverId)` step to `_clearLibraryPreferencesForServerPrefix` and to the everywhere path (every `user_*` prefix), and include the key in `_libraryPreferenceKeys`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(copies): alias-keyed remembered copy picks`.

### Task 6: CopyResolver

**Files:**
- Create: `lib/services/copy_resolver.dart`
- Modify: `lib/navigation/profile_session_screen.dart` (provide `CopyPickStore` and `CopyResolver` per profile, disposed on switch)
- Test: `test/services/copy_resolver_test.dart`

**Interfaces:**
- Consumes: Task 2 `compareCopiesByPriority`, Task 3 lookups, Task 4 `stampFromShow` / `acceptEpisodeCopy`.
- Produces:

```dart
class ResolvedCopies {
  final List<MediaItem> copies; // best-first, opened item included once
  final Set<String> failedServerIds, cancelledServerIds, unqueriedServerIds;
}
class CopyResolver {
  CopyResolver({
    required MultiServerManager serverManager,
    required DataAggregationService aggregation,
    required List<String> Function() priority,
    required MediaItem Function(MediaItem) freshWatchState, // WatchStateStore.apply
    DateTime Function() now = DateTime.now,
  });
  Future<ResolvedCopies> copiesOf(MediaItem item, {AbortController? abort});
  Future<ResolvedCopies> episodeCopiesOf(MediaItem episode, {AbortController? abort});
  ResolvedCopies? peek(MediaItem item); // cached, filtered, re-sorted, overlaid; no I/O
  void dispose();
}
```

- [ ] **Step 1: Write the failing tests** with fake clients modeled on `_Library` and a fake `MultiServerManager` whose `visibleOnlineClients` is mutable:

```dart
test('movie: opened item present once, using the opened object', ...); // Review Focus 5
test('two copies on one server in two libraries both rank', ...);     // Review Focus 3
test('episode copies inherit show stamps and rank Silo Remux > 4K > HD', ...);
test('episode lookup reuses cached show copies (one show lookup for two episodes)', ...);
test('renumbered episode on one server is dropped, others kept', ...);
test('warm cache then top server goes offline: next read picks the next copy, no refetch', ...);
test('server comes online: entry refetches that leg in the background', ...);
test('authenticationSessionId change invalidates only that server', ...);
test('TTL 5 minutes: read at 4:59 cached, at 5:01 refetched', ...); // fake_async
test('concurrent copiesOf share one future', ...);
test('freshWatchState overlay applied on every read', ...);
test('priority change re-sorts cached copies without I/O', ...);
test('accounting sets are kept distinct', ...);
```

- [ ] **Step 2: Run** `scripts/run_tests.sh test/services/copy_resolver_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** The cache key is `item.globalKey` plus, per server, `(cacheServerId, authenticationSessionId)` recorded at fetch time. Compare these at read time and refetch a server whose pair changed. Read path: `entry.copies` → keep `serverId ∈ visibleOnlineClients` → `freshWatchState` → sort with `compareCopiesByPriority(priority())`. Movie IDs come from `client.fetchExternalIds(item.id)` on the opened item's client, plus `item.guid` as `plexGuid` for Plex. Episodes: build the show query from the opened episode's show IDs (`fetchExternalIds(grandparentId)`) and title, call `findShowCopiesAcrossServers`, then for each show copy call `episodesOf`, `stampFromShow`, and filter with `acceptEpisodeCopy` (episode IDs via `fetchExternalIds`). Subscribe to library-change events through `LibraryEventSocket` the way `LibrariesProvider` does, and drop entries naming a covered library. Wire it in `profile_session_screen.dart` as `Provider(create: …, dispose: (_, r) => r.dispose())`, with `priority: () => context.read<CopyPriorityProvider>().priority`.
- [ ] **Step 4: Run.** Expected: PASS. Break the online filter, watch the offline test fail, then restore it.
- [ ] **Step 5: Commit** `feat(copies): profile-scoped copy resolver`.

### Task 7: Next episode across servers (prove on device first)

**Files:**
- Modify: `lib/screens/video_player/parts/episode_queue.dart:81`, `lib/screens/video_player/parts/episode_navigation.dart:47-200`, `lib/screens/video_player/parts/playback_reload.dart:770`, `lib/screens/video_player_screen.dart` (field)
- Test: `test/screens/video_player/cross_server_episode_advance_test.dart`

**Interfaces:**
- Consumes: Task 6 `CopyResolver.episodeCopiesOf` / `peek`, Task 4 `chooseTarget`, Task 5 `CopyPickStore.read`.
- Produces: `MediaItem? _queueAnchor` on the player state; `_loadAdjacentEpisodes({MediaItem? metadata, …})` resolves `metadata ?? _queueAnchor ?? _currentMetadata`. `_navigateToEpisode(MediaItem anchor)` sets `_queueAnchor = anchor` and reloads with the chosen copy. `_replaceScreenWithPlayer(MediaItem metadata, {MediaItem? queueAnchor, …})` gains `queueAnchor`, forwarded through `navigateToVideoPlayer(…, queueAnchor:)` into `VideoPlayerScreen`.

- [ ] **Step 1: Device proof (throwaway, not committed).** On the Android TV, temporarily make `_navigateToEpisode` reload with a hard-coded Silo copy of the next episode while playing from Plex. Record whether (a) the player opens it in place, (b) progress lands on Silo, and (c) the audio and subtitle language carry over. If (a) fails, the in-place path becomes the `_replaceScreenWithPlayer` fallback and the rest of this task uses it. Note the result in the commit message of Step 5. Revert the hack.
- [ ] **Step 2: Write the failing tests** (player harness from `test/screens/video_player/playback_reload_failure_test.dart`):

```dart
testWidgets('two advances after a cross-server switch both find next from the origin queue', ...);
testWidgets('lookup unanswered at advance plays the same-server next episode', ...);
testWidgets('multi-episode Plex file: anchor keeps playedPartId so the sibling is skipped', ...); // Review Focus 1
testWidgets('version signature is dropped when the server changes', ...);
```

- [ ] **Step 3: Run** `scripts/run_tests.sh test/screens/video_player/cross_server_episode_advance_test.dart`. Expected: FAIL.
- [ ] **Step 4: Implement.**
  - When `_episode.next` commits, start `episodeCopiesOf(next)`.
  - On advance, use `peek` with `chooseTarget` and the copy pick, or `next` itself if nothing is cached.
  - `playedPartId` passed to `loadAdjacentEpisodes` is the anchor's part when the playing copy differs from the anchor (from the anchor's `mediaVersions`), else today's `_currentMediaInfo` part.
  - `preferredVersionSignature` is `null` when `chosen.serverId != current.serverId`.
  - `playback_reload.dart:770` passes `metadata: _queueAnchor ?? metadata`.
- [ ] **Step 5: Run** the file plus `test/services/episode_navigation_service_test.dart`. Expected: PASS. Commit `feat(player): keep the episode queue on the origin server and play the best copy at each advance`.

### Task 8: `playBestCopy` and call sites

**Files:**
- Modify: `lib/utils/video_player_navigation.dart` (beside `navigateToVideoPlayer`, `:303`)
- Modify call sites: `lib/screens/media_detail/action_buttons.dart:63`; `lib/screens/media_detail_screen.dart:2945`, `:3384`, `:4499`; `lib/utils/media_navigation_helper.dart:243`, `:251`; `lib/screens/discover_screen.dart:1609`; `lib/screens/main_screen.dart:904` (`_handleShelfContentId`)
- Test: `test/utils/play_best_copy_test.dart`

**Interfaces:**
- Consumes: Tasks 4–6.
- Produces: `Future<bool?> playBestCopy(BuildContext context, {required MediaItem metadata, Duration maxWait = const Duration(seconds: 2), /* every other navigateToVideoPlayer parameter, same names and defaults */})`.

- [ ] **Step 1: Write the failing tests** (fake `CopyResolver`; spy on the launched metadata):

```dart
testWidgets('plays the top-ranked copy with the furthest viewOffsetMs', ...);
testWidgets('remembered pick beats ranking', ...);
testWidgets('resolver slower than 2 s plays the opened item', ...); // fake_async
testWidgets('completed download plays locally and is not retargeted', ...);
testWidgets('isOffline, explicit version, explicit initialPosition, watchTogetherCopy each bypass', ...);
testWidgets('external player receives the furthest offset via viewOffsetMs', ...);
testWidgets('resolver error plays the opened item', ...);
```

- [ ] **Step 2: Run** `scripts/run_tests.sh test/utils/play_best_copy_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** per §3 steps 1–5. The target is `chooseTarget(copies, pickStore.read(aliases)?.ref)`, then `target.copyWith(viewOffsetMs: furthestResumeOffsetMs(target, copies) ?? target.viewOffsetMs)`. Pass `resolveWatchState: false` for the retargeted launch, because the resolver already overlaid watch state and a second overlay of the target's key would overwrite the transferred offset. Use the caller's value for bypassed launches. Switch each listed call site; `media_navigation_helper.dart` switches only when `!isOffline`.
- [ ] **Step 4: Run** the file plus `test/utils/video_player_navigation_test.dart` and `test/screens/media_detail_screen_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(copies): plain Play starts the best-ranked copy`.

### Task 9: Detail page target, label, grouped picker, reset, "Also in"

**Files:**
- Modify: `lib/screens/media_detail_screen.dart` (`_showPlayEpisode` `:5073`; resolve on target change)
- Modify: `lib/screens/media_detail/action_buttons.dart` (`showVersionSplit` `:44`, `onPlayVersionPressed` `:107`)
- Create: `lib/widgets/copy_version_picker.dart`
- Modify: `lib/widgets/media_context_menu.dart:740` (Play Version opens the grouped picker)
- Modify: `lib/i18n/en.i18n.json` (`mediaMenu.playOn` = `"Play · $target"`, `mediaMenu.usePriorityOrder` = `"Use priority order"`, `mediaDetail.alsoIn` = `"Also in"`)
- Test: `test/screens/media_detail_screen_test.dart` (extend), `test/widgets/copy_version_picker_test.dart`

**Interfaces:**
- Consumes: Tasks 5, 6, 8.
- Produces: `MediaItem? _playbackTargetItem` (movie → `_metadata`; show → `_showPlayEpisode()`); `Future<({MediaItem copy, int versionIndex, bool reset})?> showCopyVersionPicker(BuildContext context, ResolvedCopies copies, {required bool hasPick})`.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('Play label names the target library once resolved, plain Play before', ...);
testWidgets('split segment shows for two single-version copies on two servers', ...);
testWidgets('picker groups versions by copy, best copy first, rows "Server · Library · <displayLabel>"', ...);
testWidgets('"Use priority order" row appears only with a pick and clears both stores', ...);
testWidgets('show page: rail focus change mid-lookup drops the stale result', ...);
testWidgets('Play Version on a show page resolves the episode, not the show', ...);
testWidgets('"Also in" lists other show copies and opens the chosen one', ...);
```

- [ ] **Step 2: Run** `scripts/run_tests.sh test/screens/media_detail_screen_test.dart test/widgets/copy_version_picker_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Keep an `int _copyGeneration` that increments on each target change and ignores late results.
  - A pick writes `CopyPickStore.write(copyAliases(...), CopyPick(key: copy.globalKey or show copy key, lib: library key, sig: version.signature, at: now))` and also calls the existing `saveMediaVersionPreferenceFor`.
  - Reset calls `CopyPickStore.clear` and `resetSavedMediaVersionPreferenceFor`.
  - Run `scripts/codegen.sh` after the i18n edit.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(copies): detail page shows and picks copies across servers`.

### Task 10: Copy priority settings screen

**Files:**
- Create: `lib/screens/settings/copy_priority_screen.dart`
- Modify: `lib/screens/settings/playback_settings_screen.dart` (entry row)
- Modify: `lib/i18n/en.i18n.json` (`settings.copyPriority` = `"Copy priority"`, `settings.copyPriorityUnranked` = `"Unranked (by resolution)"`)
- Test: `test/screens/settings/copy_priority_screen_test.dart`

**Interfaces:**
- Consumes: Task 1 `CopyPriorityProvider`, `LibrariesProvider` libraries.
- Produces: `CopyPriorityScreen` widget.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('lists movie, show and mixed-video libraries; excludes music and photo', ...); // defaultBrowseKinds
testWidgets('ranked rows first, then the unranked divider', ...);
testWidgets('D-pad reorder persists the new order', ...);
testWidgets('moving an unranked row up ranks it', ...);
testWidgets('stored keys for missing libraries are not shown and are dropped on next save', ...); // Review Focus 4
```

- [ ] **Step 2: Run** `scripts/run_tests.sh test/screens/settings/copy_priority_screen_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** with `DpadReorderListMixin` (`lib/focus/dpad_reorder_mixin.dart`), following its use in `lib/widgets/library_management_sheet.dart`. Rows read `"${library.serverName} · ${library.title}"`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(settings): copy priority screen`.

### Task 11: Catalog detail follows the ranking

**Files:**
- Modify: `lib/services/catalog/catalog_library_matcher.dart` (`:74`, `:145`), `lib/screens/catalog_item_detail_screen.dart:215`, `lib/navigation/profile_session_screen.dart` (pass priority to the matcher)
- Test: `test/services/catalog/catalog_library_matcher_test.dart` (extend), `test/screens/catalog_item_detail_screen_test.dart` (extend)

**Interfaces:**
- Consumes: Task 1, Task 2.
- Produces: `CatalogLibraryMatcher(MultiServerProvider multiServer, {List<String> Function()? priority})`; cached results re-sort on read.

- [ ] **Step 1: Write the failing tests**

```dart
test('matcher orders copies by priority', ...);
test('cached entry re-sorts after a priority change without a lookup', ...);
testWidgets('open catalog screen re-sorts when the priority changes', ...);
```

- [ ] **Step 2: Run** the two files. Expected: FAIL.
- [ ] **Step 3: Implement.** The screen listens to `CopyPriorityProvider` and re-runs `mergeLibraryCopies(_matches, const [], compare: …)`. Keep the focus reclaim that is already there.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(catalog): rank catalog copies by the priority list`.

### Task 12: Full suite and device verification

- [ ] **Step 1:** `dart format --set-exit-if-changed lib test`, `flutter analyze`, `scripts/codegen.sh --check`, `scripts/run_tests.sh`. Expected: all clean.
- [ ] **Step 2: Device checklist** on Android TV against the real servers. These are the spec §7 items 1–7; record a pass or fail for each with a one-line note:
  1. A movie on all three servers plays from the top-ranked library.
  2. A Silo show: episodes play from Remux > 4K > HD as ranked.
  3. Progress only on Plex resumes from Silo at Plex's position (internal player, and external player if enabled).
  4. Three autoplayed episodes in a row across a server change.
  5. A lower-copy pick sticks across episodes and across opening from another server; "Use priority order" clears it.
  6. One server off after browsing: Play starts within 2 s from the next-ranked copy.
  7. A downloaded movie plays the download while online.
- [ ] **Step 3:** Commit any fixes, each with a failing test first. Then use superpowers:finishing-a-development-branch.
