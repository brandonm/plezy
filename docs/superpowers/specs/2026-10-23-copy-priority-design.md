# Copy priority: play the best copy across servers

Status: draft for review · 2026-10-23

## Goal

One profile reaches several servers that hold the same titles: Plex (Movies,
TV Shows), Jellyfin (Movies, TV Shows) and Silo over the Jellyfin API (TV
Shows, TV Shows 4K, TV Shows 4K Remux, Movies, Movies 4K, Movies 4K Remux).
Today Play starts whichever copy the user happened to open.

After this change:

- The user ranks libraries once. Play starts the highest-ranked copy of a
  movie or episode, wherever the user opened it from.
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
- Playlists, play queues, agent/remote commands, Watch Together, offline and
  downloads, Live TV: they keep their current copy logic.

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
(`serverId:libraryId`), stored by `StorageService` beside the existing library
order and hidden libraries (`lib/services/storage_service.dart`). The new key is
added to `_libraryPreferenceKeys`, so the existing server-removal cleanup
(`_filterServerEntriesFrom…`) drops a removed server's entries. Exposed through
a small `CopyPriorityProvider` (`ChangeNotifier`, profile-scoped, same shape as
`HiddenLibrariesProvider`).

**Settings UI.** Settings → Playback → "Copy priority": a reorderable list of
every movie and show library across the profile's servers, using
`dpad_reorder_mixin.dart` so it works on a remote. Rows read
"Server · Library". Libraries absent from the stored list render below an
"Unranked (by resolution)" divider; moving one up ranks it. Music, photo and
other kinds are excluded. New strings go in `en.i18n.json` only; other locales
fall back.

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

An item's library key is `buildGlobalKey(serverId, libraryId)`. A copy with no
`libraryId` (the Jellyfin library stamp is best-effort) is treated as unranked.

The catalog detail screen's copy chooser (`catalog_item_detail_screen.dart`,
`CatalogLibraryMatcher`) sorts with the same comparator. `mergeLibraryCopies`
gains an optional comparator parameter, defaulting to `compareLibraryCopies`,
so existing callers are unchanged.

## 2. Resolving copies

**`CopyResolver`** (`lib/services/copy_resolver.dart`), provided app-wide
beside `DataAggregationService`. Its single job: given a library item, return
its copies best-first.

```dart
class ResolvedCopies {
  final List<MediaItem> copies;      // best-first, includes the opened item
  final Set<String> incompleteServerIds; // failed / timed out / cancelled
}

Future<ResolvedCopies> copiesOf(MediaItem item, {AbortController? abort});
Future<ResolvedCopies> episodeCopiesOf(MediaItem episode, {AbortController? abort});
```

- **Movie.** Read the item's external IDs (`fetchExternalIds`; Plex also
  passes its `plex://` guid), build `TitleQuery.movie`, call
  `DataAggregationService.findTitleCopiesAcrossServers`, sort with §1's
  comparator. The opened item is always included, even if the lookup missed
  it.
- **Show.** Same, with a show-level lookup. This needs a new
  `findShowCopiesAcrossServers(TitleQuery)` that returns shows rather than
  descending to episodes; `TitleCopiesLookup._titleItems` already does the
  per-server half and becomes reachable through a public method.
- **Episode.** Resolve the show's copies (cached, below), then ask each show
  copy for the episode's season and number. `_episodesOf` in
  `lib/media/title_copies.dart` becomes public (`episodesOf`). Episodes whose
  own IDs contradict the opened episode's are dropped, as
  `findTitleCopies` already does. Full metadata is fetched per copy
  (`_withVersions` → `fetchItem`), so each copy carries `viewOffsetMs`,
  `viewCount` and `mediaVersions`.
- **Cache.** In-memory, keyed by the opened item's `globalKey` (and the show's
  for episodes), 5-minute TTL, invalidated when the priority list changes
  (re-sort only) or a library-change event names a covered library (drop).
  Concurrent requests for one key share one future.
- **Deadline.** Each server leg keeps `MediaServerTimeouts.libraryLookup`;
  callers that block on a result (Play) cap their own wait separately (§3).
- **Scope.** Online, visible clients only (`visibleOnlineClients`, as the
  existing lookup does). Offline mode never calls the resolver.

## 3. Playing

**`playBestCopy(BuildContext, MediaItem item, {Duration maxWait})`** in
`lib/utils/video_player_navigation.dart`, wrapping `navigateToVideoPlayer`:

1. Start (or join) `CopyResolver.copiesOf` / `episodeCopiesOf`.
2. Wait at most `maxWait` (default 2 s; 0 when the detail page already holds
   a result). On timeout or error, play `item` exactly as today.
3. Choose the target: the remembered pick (§4) if it resolves to a copy in the
   result, otherwise `copies.first`.
4. Compute the resume position (below) and call `navigateToVideoPlayer` with
   the target's metadata and that start position.

Call sites:

- Detail page Play (`lib/screens/media_detail/action_buttons.dart`) and the
  episode Play buttons in `media_detail_screen.dart`.
- Direct play from tiles: `lib/utils/media_navigation_helper.dart` (episode and
  movie branches, online only), Home hero (`discover_screen.dart`).
- "Play" in `lib/widgets/media_context_menu.dart`.

Only plain Play goes through it. "Play from beginning" and other explicit
variants are listed in the implementation plan per call site.

**Resume position.** Let `furthest` be the largest `viewOffsetMs` among copies
that are in progress (`hasActiveProgress`). Copies marked watched contribute
nothing, so a finished copy elsewhere never makes Play start at the credits.
If no copy is in progress, start where the target's own state says (resume
prompt rules unchanged). The chosen position goes through the existing
`requested` resume path, so the "resume / start over" prompt behaves as it
does today.

**Detail page.** `media_detail_screen.dart` calls `CopyResolver` when it
loads and does not wait for it.

- Play's label gains the target once known: "Play · Silo 4K Remux". On a show
  page the label belongs to the episode Play would start.
- The split "Play Version" segment appears when the resolved copies hold more
  than one version in total, not only when one item has several. Its picker
  lists versions grouped by copy, best copy first, each row
  "Server · Library · 2160p HEVC 68 Mbps" (existing `displayLabel`).
- Picking a row plays that copy and version and saves the pick (§4).
- An "Also in: …" row on the show page lists other show copies; selecting one
  opens that copy's show page.

## 4. Remembered picks

Today's `mediaVersionPreferences` (`SettingsService`) are keyed by the opened
server's series / movie key (`_mediaVersionPreferenceKey`), so a pick made
from Silo would never be found when the same show is opened from Plex. Copy
picks therefore get their own store:

- **Key:** catalogue identity, not server. `movie:<id>` / `show:<id>`, where
  `<id>` is the first available of `tmdb:`, `tvdb:`, `imdb:`. A title with no
  external IDs cannot carry a cross-server pick; its in-server version pick
  still works through the existing store.
- **Value:** `{lib: "serverId:libraryId", sig: versionSignature?, at: ms}`.
- **Scope:** per profile, in `StorageService`, capped at 500 entries with the
  same oldest-first eviction as the existing store; server removal drops
  entries for that server.
- **Read:** in `playBestCopy` step 3. The pick wins if a copy from that
  library is in the result; `sig` then chooses the version within it
  (`MediaVersion.findMatchingIndex`). If the library's copy is missing
  (server offline, title deleted) the pick is ignored for this play and kept.
- **Write:** only from an explicit pick in the Play Version picker, never from
  a plain Play or a fallback, matching the existing store's rule.
- **Reset:** the existing "reset version" action clears both stores for the
  title.

## 5. Next episode in the player

`EpisodeNavigationService.loadAdjacentEpisodes` loads the next episode from
the playing server, as today. The player then asks
`CopyResolver.episodeCopiesOf(next)` in the background and, if it answers
before the advance, replaces `_episode.next` with the chosen copy (pick, then
ranking). Episode and show results are cached, so this is usually one request
per server.

`_navigateToEpisode` reloads in place with the chosen copy. Reading the code,
`_reloadMediaInPlace` resolves the playback client from the metadata it is
given (`PlaybackSourceResolver(serverManager: …)` → `reportingClient`), so a
server switch should work in place. **This is unverified** and is the first
thing the implementation proves on a device. If an in-place server switch
fails, the advance uses `_replaceScreenWithPlayer` instead.

Across a server switch, stream ids mean nothing. The existing preference path
(`preserveCurrentTrackSelection` with `_sessionAudioPreference` and subtitle
preferences, matched by language and codec) carries track choices;
`useCurrentAudioStreamSelection` stays false, as it already is for episode
changes. The carried version signature is dropped when the server changes;
the copy pick or ranking chooses the version.

If the lookup has not answered when the advance happens, play the
same-server next episode, as today.

## 6. Failure handling

- A server that fails, times out or is cancelled contributes no copies and is
  reported in `incompleteServerIds`; the others still rank.
- Any resolver failure, timeout or empty result makes Play behave exactly as
  it does today. The resolver can delay Play by at most `maxWait`; it can
  never block it.
- Failures are logged (`appLogger.w`), not shown.
- The Play label falls back to plain "Play" until a result exists.

## 7. Testing

Unit:

- `compareCopiesByPriority`: ranked order; ranked beats unranked; unranked by
  resolution; tie fallthrough; copy with no `libraryId` is unranked; total and
  stable.
- Resume position: furthest in-progress wins; watched copies ignored; no
  progress anywhere.
- Copy-pick store: identity key choice (tmdb, then tvdb, then imdb); missing
  IDs; stale pick ignored and kept; eviction; server-removal cleanup; reset
  clears both stores.
- `CopyResolver` with fake `MediaServerClient`s: opened item always present;
  per-server failure lands in `incompleteServerIds`; episode lookup reuses the
  cached show copies (asserted by call counts); TTL expiry; concurrent
  requests share one future.
- `playBestCopy`: timeout plays the opened item; pick beats ranking; ranking
  used without a pick.

Widget:

- Play label with and without a result; grouped Play Version picker order;
  the split segment appears for single-version copies on two servers.

Each fix is proved by breaking it and watching its test fail.

On device (Android TV), against the real servers:

1. A movie on all three servers plays from the top-ranked library.
2. An episode ranked to Silo with progress only on Plex resumes at Plex's
   position, from Silo.
3. Next-episode autoplay that changes server (§5).
4. A pick of a lower copy sticks across episodes and across opening the show
   from a different server; reset clears it.
5. One server powered off: Play still starts within the wait cap.

## Open questions for review

- Silo's write support for playback progress through its Jellyfin API is
  unknown. This design does not need it, beyond the normal progress reports
  every Jellyfin server already receives while playing.
- Whether the catalogue-identity key in §4 should prefer TVDB for shows
  (Plex and Jellyfin both commonly carry it) instead of TMDB first.
