# Copy priority: play the best copy across servers

Status: draft, revision 2 (after Codex review) · 2026-10-23

## Goal

One profile reaches several servers that hold the same titles: Plex (Movies,
TV Shows), Jellyfin (Movies, TV Shows) and Silo over the Jellyfin API (TV
Shows, TV Shows 4K, TV Shows 4K Remux, Movies, Movies 4K, Movies 4K Remux).
Today Play starts whichever copy the user happened to open.

After this change:

- The user ranks libraries. Play starts the highest-ranked copy of a movie or
  episode, wherever the user opened it from.
- The detail page shows every copy, and the user can pick a lower one. That
  pick sticks for the movie or series until reset.
- Play resumes from the furthest progress across copies, so ranking a server
  above the one holding the progress never loses the user's place.

The user watches only in this app, on several TVs. Watch-state sync between
servers is a separate, later project; this design must not depend on it.

### Out of scope

- Watch-status / progress sync between servers (next project).
- Merged Home rows other than the existing Continue Watching dedup.
- Merged library browsing.
- Skipping copies that would transcode on the current device.
- Matching episodes whose season/episode numbering differs between servers
  (absolute vs aired order, specials). Such episodes fall back to the opened
  copy (§2, episode matching).
- Playlists, play queues, collections, shuffle, agent/remote commands, Watch
  Together, trailers, explicit external-player launches, "Play from
  beginning", offline mode, Live TV: they keep their current copy logic.

## Decisions taken in brainstorming

| Question | Decision |
| --- | --- |
| How "best" is decided | A user-ordered list of libraries (not automatic) |
| Resume position | Furthest progress across all copies |
| TV show page | Shows the copy the user opened; each episode plays its best copy |
| Manual pick of a lower copy | Remembered per movie / series |
| When copies are looked up | When the detail page opens (background), with a short wait on Play |
| Catalog detail chooser | Follows the same ranking |

## 1. Priority list

**Storage.** A per-profile ordered `List<String>` of library global keys
(`serverId:libraryId`) in `StorageService`, beside library order and hidden
libraries (`lib/services/storage_service.dart`). Server-removal cleanup is
explicit, not implied by `_libraryPreferenceKeys` (that list only drives the
whole-preference clear at `storage_service.dart:372`): the new key is added to
`_clearLibraryPreferencesForServerPrefix` and
`clearLibraryPreferencesForServerEverywhere` next to `_keyLibraryOrder`, and
to `_libraryPreferenceKeys` for the full clear. Exposed through a
profile-scoped `CopyPriorityProvider` (`ChangeNotifier`, same shape as
`HiddenLibrariesProvider`).

**Across TVs.** `StorageService` is device-local SharedPreferences. See
"Open questions" for how the ranking reaches the user's other TVs.

**Settings UI.** Settings → Playback → "Copy priority": a reorderable list of
every video library across the profile's servers, using
`dpad_reorder_mixin.dart` so it works on a remote. A library qualifies when
its `kind` is movie or show, or when it is mixed (`MediaKind.unknown`) and its
`defaultBrowseKinds` contains movie or show (`lib/media/media_library.dart:14`).
Rows read "Server · Library". Libraries absent from the stored list render
below an "Unranked (by resolution)" divider; moving one up ranks it. New
strings go in `en.i18n.json` only; other locales fall back.

**Not the sidebar order.** The sidebar library order is navigation preference;
quality priority is a different question and gets its own list.

**Comparator.** `compareCopiesByPriority(List<String> priority)` returns a
comparator, added beside `compareLibraryCopies` in
`lib/media/media_item_merge.dart`:

1. Ranked libraries by their index in `priority`; any ranked copy beats any
   unranked one.
2. Unranked copies by best resolution (`_bestResolutionHeight`), highest
   first.
3. Ties fall through to `compareLibraryCopies` (library title, server name,
   global key), so the order stays total and stable across passes.

A copy's library key is `buildGlobalKey(serverId, libraryId)`. A copy with no
`libraryId` is unranked. §2 guarantees every Jellyfin copy it returns is
stamped, so "no `libraryId`" means the stamp genuinely failed.

**Catalog detail.** `CatalogLibraryMatcher` sorts with
`compareLibraryCopies` (`catalog_library_matcher.dart:145`) and reuses
complete cache entries indefinitely (`:74`); the screen re-sorts its own
`_matches` (`catalog_item_detail_screen.dart:215`). All three take the
priority comparator, and both the matcher and an open screen listen to
`CopyPriorityProvider` and re-sort in memory on change, with no new network
lookup. `mergeLibraryCopies` gains an optional comparator parameter
defaulting to `compareLibraryCopies`, so other callers are unchanged.

## 2. Resolving copies

**`CopyResolver`** (`lib/services/copy_resolver.dart`). Its job: given a
library item, return its copies best-first.

```dart
class ResolvedCopies {
  final List<MediaItem> copies;            // best-first, includes the opened item
  final Set<String> failedServerIds;       // from LibraryLookupResult,
  final Set<String> cancelledServerIds;    // kept distinct, not collapsed
  final Set<String> unqueriedServerIds;
}

Future<ResolvedCopies> copiesOf(MediaItem item, {AbortController? abort});
Future<ResolvedCopies> episodeCopiesOf(MediaItem episode, {AbortController? abort});
```

**Lifetime and scope.** One resolver per profile session, created and
disposed by the same binder that owns the profile's providers. A profile
switch discards it and its cache. Within a session, cache keys also include
each client's `cacheServerId` scope and `authenticationSessionId`
(`media_server_client.dart:127`), so a re-authentication on one server
invalidates that server's entries. This follows the scope rule in
`watch_state_store.dart:196`: public server ids are shared between users of
one server, so they never key user state alone.

**Movie.** Read the item's external IDs (`fetchExternalIds`; Plex also passes
its `plex://` guid), build `TitleQuery.movie`, call
`DataAggregationService.findTitleCopiesAcrossServers` (which returns a
`LibraryLookupResult`, `data_aggregation_service.dart:970`), sort with §1's
comparator. The opened item is always included, even if the lookup missed it.

**Show.** `findTitleCopies` has no show-level result: every non-movie query
descends to episodes (`title_copies.dart:64`). Add
`findShowCopies(TitleQuery)` on `TitleCopiesLookup`, a public wrapper over
`_titleItems(kind: MediaKind.show, …)`, and
`findShowCopiesAcrossServers` on `DataAggregationService` with the same
fan-out and deadline as its movie sibling. Jellyfin show matches are already
library-stamped through `/Ancestors` (`jellyfin_client/parts/browse.dart:1686`).

**Episode.** Resolve the show's copies (cached), then ask each show copy for
the episode's season and number via a public `episodesOf` (today
`_episodesOf`, `title_copies.dart:145`). That helper returns exact-number
children only, with no library stamp and no ID check, so the resolver adds
both:

- **Library stamp.** Every episode inherits its show copy's `libraryId` and
  `libraryTitle`. Jellyfin item DTOs never carry a library
  (`jellyfin_mappers.dart:289`), and episode children arrive with inline
  `MediaSources`, so nothing downstream would stamp them. Without this every
  Silo episode is unranked and HD / 4K / Remux collapse to a resolution tie.
- **Episode matching.** A candidate is accepted only if (a) when both it and
  the opened episode expose episode-level external IDs, at least one agrees
  and none contradict (`contradicts`, `title_copies.dart:209`); and (b) when
  either side lacks IDs, both durations are known and differ by at most 10%.
  Otherwise the candidate is dropped. A server whose numbering differs
  therefore contributes nothing for that episode rather than a wrong episode.

**Enrichment keeps context.** `_withVersions` fetches only rows lacking inline
versions and replaces the row with the bare `fetchItem` result
(`title_copies.dart:188`), which drops a Jellyfin library stamp. Change it to
fold the fetched item through `mergeFetchedMediaItem`
(`media_item_merge.dart:30`) so the stamp survives. Progress is not taken from
enrichment at all; see "Fresh watch state".

**Fresh watch state.** Lookups can be minutes old, and Jellyfin
`UserDataChanged` does not reach the library-event channel
(`media_browser_library_event_socket.dart:77`). Every read of cached copies
(Play, the label, next episode) overlays the current `WatchStateStore` state
for each copy (`watch_state_store.dart:105`) before choosing a target or a
resume position.

**Cache.** In memory, keyed as above by the opened item (and the show for
episodes), 5-minute TTL. Concurrent requests for one key share one future.

- Every read filters the cached copies to clients that are currently in
  `visibleOnlineClients` (`multi_server_manager.dart:439`) and re-sorts them.
  A powered-off top server drops out at once.
- A server coming online, or the priority list changing, does not drop
  entries. Coming online marks entries "incomplete for that server", and the
  next read refetches that server's leg in the background.
- A library-change event naming a covered library drops the entry.

**Deadline.** Each server leg keeps `MediaServerTimeouts.libraryLookup`.
Callers that block on a result (Play) cap their own wait (§3).

## 3. Playing

**`playBestCopy`** in `lib/utils/video_player_navigation.dart` takes the same
parameters as `navigateToVideoPlayer` (`isOffline`, `onRefresh`,
`isLaunchCurrent`, `resolveWatchState`, and the rest; `video_player_navigation.dart:303`)
plus `maxWait`, and forwards them unchanged. Steps:

1. **Bypasses.** Call `navigateToVideoPlayer` with the opened item unchanged
   when: `isOffline`; the caller passed an explicit version, media source,
   start position or Watch Together copy; or the opened item has a completed
   download (`downloadProvider.getCompletedDownload(item.globalKey)`). Plain
   Play on a downloaded item deliberately plays the local file
   (`video_player_navigation.dart:345`). Retargeting first would change the
   `globalKey` and miss it.
2. Start (or join) `copiesOf` / `episodeCopiesOf`. Wait at most `maxWait`
   (default 2 s; 0 when the detail page already holds a result). On timeout,
   error or an empty result, play the opened item exactly as today.
3. **Target.** The remembered pick (§4) if it resolves to a copy in the
   result, otherwise `copies.first`.
4. **Resume.** Among copies, after the `WatchStateStore` overlay, take those
   with `!isWatched && hasActiveProgress`. `hasActiveProgress` alone does not
   exclude watched items (`media_item.dart:382`), so a watched copy with a
   leftover offset would otherwise win. Of those, ignore any whose duration
   differs from the target's by more than 5% (a different cut or edition) and
   take the largest `viewOffsetMs`. If none remain, the target keeps its own
   state.
5. Launch with the **target's metadata copied with that `viewOffsetMs`**,
   not with `initialPosition`. The internal player resolves its start from
   `viewOffsetMs` when nothing explicit is requested
   (`playback_open.dart:70`), and the external-player path reads only
   `metadata.viewOffsetMs` (`external_player_service.dart:91`), so a requested
   position would be lost there. There is no resume / start-over prompt on
   this path. Behavior is "start at the chosen position", as today.

**Call sites (plain Play only):**

- Detail hero Play and first-episode fallbacks:
  `media_detail/action_buttons.dart:63`, `media_detail_screen.dart:3384`.
- Episode-list cards: `media_detail_screen.dart:2945`.
- TV detail episode rail: `media_detail_screen.dart:4499`.
- Movie and episode tile activation (Continue Watching, rows):
  `media_navigation_helper.dart:238` and `:251`, online only.
- Home hero: `discover_screen.dart:1586`.
- Android TV system shelf launch: `main_screen.dart:904`
  (`_handleShelfContentId`).

`media_context_menu.dart` has no plain Play; only its "Play Version" entry
(`:740`) switches to the grouped picker below.

**Detail page.** One `_playbackTargetItem` drives both Play and Play Version.
On a movie page it is the movie. On a show page it is the episode Play would
start: on TV the focused rail episode, otherwise on-deck
(`_showPlayEpisode`, `media_detail_screen.dart:5073`). Today `onPlayVersionPressed` passes the page
metadata (`action_buttons.dart:107`), which is a show on a show page, and that
changes.

- The page resolves copies for the current `_playbackTargetItem` and
  re-resolves when it changes. Each request carries a generation number, and
  late results for an older target are dropped.
- Play's label gains the target once known: "Play · Silo 4K Remux".
- The split "Play Version" segment appears when the resolved copies hold more
  than one version in total. Its picker groups versions by copy, best copy
  first; each row reads "Server · Library · 2160p HEVC 68 Mbps" (existing
  `displayLabel`). Picking a row plays that copy and version and saves the
  pick (§4).
- An "Also in: …" row on the show page lists other show copies; selecting one
  opens that copy's show page.

## 4. Remembered picks

Today's `mediaVersionPreferences` (`SettingsService`, shared across profiles)
are keyed `serverId:(grandparentId ?? id)` (`video_player_navigation.dart:177`),
so a pick made from Silo would never be found when the same show is opened
from Plex. Copy picks get their own store:

- **Identity.** A record is filed under *every* catalogue alias the title
  exposes across its resolved copies: `movie|show` plus each of `tmdb:`,
  `tvdb:`, `imdb:` present on any copy. A read looks up all aliases of the
  opened title and takes the newest matching record. Opening from a server
  that carries only TVDB still finds a pick written where TMDB and TVDB were
  both present. A title with no external IDs cannot carry a cross-server
  pick; the existing in-server store still works for it.
- **Value.** `{key: globalKey of the chosen copy (movie) or show copy
  (series), lib: "serverId:libraryId", sig: versionSignature?, at: ms}`.
  `key` distinguishes two editions in one library; `lib` is the fallback when
  that item id is gone (re-added to the library).
- **Scope.** Per profile, in `StorageService`. Capped at 500 records with the
  existing oldest-first eviction. Server removal deletes records whose `lib`
  names that server, through an explicit pass in both server-cleanup paths;
  the string-list filter cannot reach inside a JSON map.
- **Read** (`playBestCopy` step 3). Match `key`, else `lib`; `sig` then
  chooses the version (`MediaVersion.findMatchingIndex`). If the copy is
  missing (server offline, title deleted), ignore the pick for this play and
  keep it.
- **Write** only from an explicit pick in the Play Version picker, never from
  a plain Play or a fallback, the same rule as the existing store.
- **Reset UI (new).** There is no reset in the UI today; the helper's only
  caller is the agent command (`agent_scoped_settings_commands.dart:338`).
  Add "Use priority order" as the first row of the Play Version picker when a
  pick exists. It clears the copy pick and the in-server version preference
  for the title.

## 5. Next episode in the player

**Queue anchoring.** Today, after an in-place reload, `_loadAdjacentEpisodes`
runs for the new item (`playback_reload.dart:755`). An episode from another
server is not a member of the active series queue, and its series id differs
from the queue's context key, so `EpisodeNavigationService` returns failed
(`episode_navigation_service.dart:152`, `:167`). Autoplay would work once and
then stop.

So the queue stays anchored to the **origin** server, the one the user
started from, and copies are swapped only at the moment of playback:

- The player keeps `_queueAnchor`, the origin-server episode for the current
  position, separately from the playing copy's metadata.
- `_loadAdjacentEpisodes` and `setCurrentItem` take `_queueAnchor`, never a
  cross-server copy. The series queue, its context key and shuffle/playlist
  protection are untouched.
- When `_episode.next` loads, the player resolves `episodeCopiesOf(next)` in
  the background. On advance, `_navigateToEpisode` sets
  `_queueAnchor = next` and reloads with the chosen copy (pick, then
  ranking), or with `next` itself if the lookup has not answered.
- Progress reports already follow the reloaded metadata's client
  (`PlaybackSourceResolver` → `reportingClient`, `playback_source_resolver.dart:26`,
  verified in code), so the copy's server receives its progress.

The origin's episode list decides what "next" is, so the run continues
through episodes the top-ranked library lacks, played from whichever copy is
best for each.

**Fallback.** If an in-place reload across servers fails on the device,
`_navigateToEpisode` uses `_replaceScreenWithPlayer` with the chosen copy and
passes `_queueAnchor` along so the new screen keeps the origin queue. Whether
in-place cross-server reload works end-to-end is **unverified on a device**,
and it is the first thing implementation proves.

**Tracks.** Across a server switch, stream ids mean nothing. The existing
preference path (`preserveCurrentTrackSelection` with
`_sessionAudioPreference` and subtitle preferences, matched by language and
codec) carries track choices; `useCurrentAudioStreamSelection` is already
false for episode changes. When the server changes, the carried version
signature is dropped; the pick or ranking chooses the version.

## 6. Failure handling

- A server that fails, times out or is cancelled contributes no copies and is
  reported in its accounting set; the others still rank.
- Any resolver failure, timeout or empty result makes Play behave exactly as
  it does today. The resolver can delay Play by at most `maxWait`; it never
  blocks it.
- Failures are logged (`appLogger.w`), not shown.
- The Play label falls back to plain "Play" until a result exists.

## 7. Testing

Unit:

- `compareCopiesByPriority`: ranked order; ranked beats unranked; unranked by
  resolution; tie fallthrough; copy with no `libraryId` unranked; total and
  stable.
- Episode copies from a Jellyfin show copy inherit its library stamp (Silo HD,
  4K and Remux episodes rank by the list, not by a tie).
- `_withVersions` enrichment keeps a Jellyfin library stamp.
- Episode matching: agreeing IDs accepted; contradicting IDs dropped; no IDs
  with a duration within 10% accepted, outside dropped; renumbered episode
  with matching IDs found where reachable, otherwise falls back to the opened
  copy.
- Resume: furthest in-progress wins; watched copy with a residual offset
  ignored; copy with a >5% duration difference ignored; `WatchStateStore`
  overlay beats a stale cached offset.
- Cache: warm entry, then the top server goes offline, so the next read picks
  the next copy; profile switch discards the cache; re-auth on one server
  invalidates only it; concurrent requests share one future; TTL expiry.
- Copy-pick store: written under all aliases and found from a copy carrying
  only one; `key` beats `lib`; two editions in one library; stale pick
  ignored and kept; eviction; server-removal cleanup in both paths; reset
  clears both stores.
- Priority-list server-removal cleanup in both paths.
- `playBestCopy`: timeout plays the opened item; pick beats ranking; a
  completed download plays locally and is not retargeted; explicit version or
  start position bypasses; external-player launch receives the furthest
  offset through `viewOffsetMs`.

Widget:

- Play label with and without a result; grouped picker order and the "Use
  priority order" row; the split segment appears for single-version copies on
  two servers.
- Show page: changing rail focus while a lookup is in flight drops the stale
  result.
- Catalog detail: changing the priority with the screen open re-sorts without
  a lookup.

Player:

- Two successive next-episode advances after a cross-server switch: the
  second advance still finds `next` from the origin queue.

Each fix is proved by breaking it and watching its test fail.

On device (Android TV), against the real servers:

1. A movie on all three servers plays from the top-ranked library.
2. A Silo show with HD, 4K and Remux libraries: episodes play from the
   library ranked first.
3. An episode ranked to Silo with progress only on Plex resumes at Plex's
   position, from Silo, in the internal player and, if enabled, the external
   player.
4. Three autoplayed episodes in a row across a server change.
5. A pick of a lower copy sticks across episodes and across opening the show
   from a different server; "Use priority order" clears it.
6. One server powered off after browsing: Play still starts within the wait
   cap, from the next-ranked copy.
7. A downloaded movie plays the download while online.

## Open questions

- **Several TVs.** The ranking and picks are stored per device. Options:
  (a) per device, and the user ranks on each TV; (b) add both keys to
  settings export/import (`settings_export_service.dart:91`, whose registry is
  closed today), so the user ranks once and imports on the other TVs; (c) a
  server-side store shared by every TV, which belongs with the sync project.
  Awaiting the user's choice.
- Silo's write support for playback progress through its Jellyfin API is
  unknown. This design needs only the normal progress reports every Jellyfin
  server receives while playing.
