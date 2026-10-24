import '../utils/external_ids.dart';
import '../utils/global_key_utils.dart';
import 'ids.dart';
import 'media_item.dart';
import 'media_kind.dart';
import 'title_copies.dart' show contradicts;

/// A remembered pick as the selection rules see it: [key] names the chosen
/// copy (movie) or show copy (series), [lib] is `serverId:libraryId`, [sig]
/// the version signature.
typedef CopyPickRef = ({String key, String lib, String? sig});

/// [episode] carrying the library stamp of [showCopy], unless it already has a
/// `libraryId` of its own.
MediaItem stampFromShow(MediaItem episode, MediaItem showCopy) {
  if (episode.libraryId != null) return episode;
  return episode.copyWith(libraryId: showCopy.libraryId, libraryTitle: showCopy.libraryTitle);
}

/// Whether [candidate] is the same episode as [opened].
///
/// Season and episode number must match first (missing counts as -1, so S00E03
/// never matches S01E03). Then one contradicting catalogue ID rejects; a shared
/// provider with an equal value accepts. When both sides expose IDs, that is
/// the whole decision. Otherwise both durations must be known (above zero) and
/// within 10% of [opened]'s.
bool acceptEpisodeCopy({
  required MediaItem opened,
  required ExternalIds openedIds,
  required MediaItem candidate,
  required ExternalIds candidateIds,
}) {
  if ((candidate.parentIndex ?? -1) != (opened.parentIndex ?? -1)) return false;
  if ((candidate.index ?? -1) != (opened.index ?? -1)) return false;
  if (contradicts(openedIds, candidateIds)) return false;
  // Both sides expose IDs: one must agree, or the copy is dropped.
  if (openedIds.hasAny && candidateIds.hasAny) return openedIds.intersects(candidateIds);

  // Either side has no IDs to go on. Exact integer math: |a - b| <= 10% of a.
  final a = opened.durationMs;
  final b = candidate.durationMs;
  if (a == null || b == null || a <= 0 || b <= 0) return false;
  return (a - b).abs() * 10 <= a;
}

/// The largest in-progress `viewOffsetMs` among [copies] whose length is within
/// 5% of [target]'s, or null when none qualifies.
///
/// `hasActiveProgress` ignores watched status, so a watched copy with a
/// leftover offset is excluded here. Copies of unknown length are ignored.
int? furthestResumeOffsetMs(MediaItem target, Iterable<MediaItem> copies) {
  final targetDuration = target.durationMs;
  if (targetDuration == null) return null;
  int? best;
  for (final copy in copies) {
    if (copy.isWatched || !copy.hasActiveProgress) continue;
    if ((copy.durationMs! - targetDuration).abs() * 20 > targetDuration) continue;
    final offset = copy.viewOffsetMs!;
    if (best == null || offset > best) best = offset;
  }
  return best;
}

/// The key a remembered pick is filed under for [copy]: the show copy's key
/// for an episode, since series picks name the show, otherwise its own.
String copyPickKey(MediaItem copy) {
  if (copy.kind == MediaKind.episode && copy.grandparentId != null && copy.serverId != null) {
    return buildGlobalKey(ServerId(copy.serverId!), copy.grandparentId!);
  }
  return copy.globalKey;
}

/// The copy to play: the one [pick] names by key, else by library, else
/// [rankedCopies]'s first. [rankedCopies] must not be empty.
MediaItem chooseTarget(List<MediaItem> rankedCopies, CopyPickRef? pick) {
  if (pick != null) {
    for (final copy in rankedCopies) {
      if (copyPickKey(copy) == pick.key) return copy;
    }
    for (final copy in rankedCopies) {
      if (copy.libraryGlobalKey == pick.lib) return copy;
    }
  }
  return rankedCopies.first;
}
