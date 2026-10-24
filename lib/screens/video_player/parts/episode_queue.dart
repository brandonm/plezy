part of '../../video_player_screen.dart';

/// How long before the end of an item the next episode's copy lookup is
/// re-issued at the latest ([_VideoPlayerEpisodeQueueMethods._refreshCopiesOfNextNearEnd]).
const _nearEndCopyLookupLead = Duration(seconds: 90);

extension _VideoPlayerEpisodeQueueMethods on VideoPlayerScreenState {
  /// Ensure a play queue exists for sequential episode playback
  Future<void> _ensurePlayQueue() async {
    if (!mounted) return;

    // Download/offline library mode uses the local downloaded queue instead.
    if (_offlineLibraryMode) return;

    // Skip play queue for live TV (would interfere with tuner session)
    if (widget.isLive) return;

    // The queue belongs to the origin entry when another library's copy of it
    // plays.
    final queueItem = _queueAnchor ?? _currentMetadata;
    if (!queueItem.isEpisode) {
      return;
    }

    // Plex-only — Jellyfin's local queue is published by
    // EpisodeNavigationService._ensureLocalEpisodeQueue from
    // _loadAdjacentEpisodes, so this method is a no-op for it.
    if (queueItem.backend != MediaBackend.plex) return;

    try {
      final client = context.getPlexClientForServer(ServerId(queueItem.serverId!));

      final playbackState = context.read<PlaybackStateProvider>();

      // For episodes, grandparentId points to the show
      final showRatingKey = queueItem.grandparentId;
      if (showRatingKey == null) {
        appLogger.d('Episode missing grandparentId, skipping play queue creation');
        return;
      }

      // Preserve any queue this item belongs to — playlist, collection,
      // or same-show queue. `isItemInActiveQueue` is the same gate
      // VideoPlayerScreen.initState uses; a context-key check alone would
      // wipe a playlist queue (its key is the playlist id, not the show).
      // Only when the active queue is genuinely stale (item not in it)
      // do we clobber and create a fresh show queue.
      if (playbackState.isItemInActiveQueue(queueItem)) {
        playbackState.setCurrentItem(queueItem);
        appLogger.d('Using existing play queue (context: ${playbackState.shuffleContextKey})');
        return;
      }
      if (playbackState.isQueueActive) {
        appLogger.d('Resetting stale play queue (was: ${playbackState.shuffleContextKey}, now: $showRatingKey)');
        playbackState.clearShuffle();
      }

      appLogger.d('Creating sequential play queue for show $showRatingKey');
      final playQueue = await client.createShowPlayQueue(
        showRatingKey: showRatingKey,
        shuffle: 0,
        startingEpisodeKey: queueItem.id,
        librarySectionID: queueItem.libraryId,
        librarySectionTitle: queueItem.libraryTitle,
      );

      if (playQueue != null && playQueue.items != null && playQueue.items!.isNotEmpty) {
        await playbackState.setPlaybackFromPlayQueue(playQueue, showRatingKey);
        playbackState.setPlayQueueWindowFetcher(
          (id, {center, window = 50}) => client.getPlayQueue(
            id,
            center: center,
            window: window,
            librarySectionID: queueItem.libraryId,
            librarySectionTitle: queueItem.libraryTitle,
          ),
        );

        appLogger.d('Sequential play queue created with ${playQueue.items!.length} items');
      } else {
        appLogger.w('Plex returned no usable sequential play queue; falling back to a local series queue');
      }
    } catch (e, st) {
      appLogger.w('Could not create Plex play queue; falling back to a local series queue', error: e, stackTrace: st);
    }
  }

  Future<void> _loadAdjacentEpisodes({MediaItem? metadata, _PlaybackAttempt? attempt}) async {
    if (!mounted || widget.isLive) return;

    final targetMetadata = metadata ?? _queueAnchor ?? _currentMetadata;
    try {
      final adjacentEpisodes = _offlineLibraryMode
          ? _loadAdjacentEpisodesOffline(targetMetadata)
          : await _episode.navigation.loadAdjacentEpisodes(
              context: context,
              metadata: targetMetadata,
              playedPartId: _queuePlayedPartId(targetMetadata),
            );
      _commitAdjacentEpisodes(targetMetadata, adjacentEpisodes, attempt);
    } catch (e, st) {
      appLogger.w('Could not load adjacent episodes', error: e, stackTrace: st);
      _commitAdjacentEpisodes(targetMetadata, const AdjacentEpisodes.failed(), attempt);
    }
  }

  /// Load next/previous episodes from locally downloaded content.
  AdjacentEpisodes _loadAdjacentEpisodesOffline(MediaItem metadata) {
    if (!metadata.isEpisode) return const AdjacentEpisodes.unavailable();

    final showKey = metadata.seriesGlobalKey;
    if (showKey == null) return const AdjacentEpisodes.unavailable();

    try {
      final downloadProvider = context.read<DownloadProvider>();
      final episodes = downloadProvider.getDownloadedEpisodesForShow(showKey);
      if (episodes.isEmpty) return const AdjacentEpisodes.failed();

      // The shared client-side watch order (Specials placed per the
      // specialsOrdering preference; no server order exists offline), so
      // offline next/prev matches what "download next N" selects and the
      // offline OnDeck list (#1416/#1414/#1952). Copy first so the provider's
      // cached list isn't reordered.
      final sorted = List<MediaItem>.from(episodes);
      sortEpisodesByWatchOrder(sorted);
      final currentIdx = sorted.indexWhere((ep) => ep.id == metadata.id);
      if (currentIdx == -1) return const AdjacentEpisodes.failed();

      // Same-file siblings are skipped by file-path intersection of the
      // stored metadata (#1500) — offline media info doesn't carry the
      // server part id, so the helpers compare the items' own parts.
      final previous = previousEpisodeSkippingSameFile(sorted, currentIdx);
      final next = nextEpisodeSkippingSameFile(sorted, currentIdx);
      return AdjacentEpisodes(
        next: next,
        previous: previous,
        nextStatus: next == null ? QueueNavigationStatus.boundary : QueueNavigationStatus.found,
        previousStatus: previous == null ? QueueNavigationStatus.boundary : QueueNavigationStatus.found,
      );
    } catch (e, st) {
      appLogger.w('Could not load offline adjacent episodes', error: e, stackTrace: st);
      return const AdjacentEpisodes.failed();
    }
  }

  /// The part the queue compares against to skip sibling entries of a Plex
  /// multi-episode file (#1500) for [queueItem].
  ///
  /// Normally the part actually being played: MediaSourceInfo carries the
  /// Plex numeric part id; MediaPart.id is its string form. While another
  /// server's copy plays, its part id names nothing on the queue's server (or
  /// an unrelated part there), so the entry's own part stands in: the one in
  /// the version matching what plays, else its first version.
  String? _queuePlayedPartId(MediaItem queueItem) {
    if (queueItem.globalKey == _currentMetadata.globalKey) return _currentMediaInfo?.partId?.toString();
    final versions = queueItem.mediaVersions ?? const <MediaVersion>[];
    if (versions.isEmpty) return null;
    final playing = _effectiveSelectedMediaIndex >= 0 && _effectiveSelectedMediaIndex < _availableVersions.length
        ? _availableVersions[_effectiveSelectedMediaIndex].signature
        : null;
    final index = (playing == null ? null : MediaVersion.findMatchingIndex(versions, {playing})) ?? 0;
    final parts = versions[index].parts;
    return parts.isEmpty ? null : parts.first.id;
  }

  void _commitAdjacentEpisodes(MediaItem targetMetadata, AdjacentEpisodes adjacentEpisodes, _PlaybackAttempt? attempt) {
    if (!mounted ||
        (_queueAnchor ?? _currentMetadata).globalKey != targetMetadata.globalKey ||
        (attempt != null && !attempt.isCurrent)) {
      return;
    }
    _setPlayerState(() {
      _episode.next = adjacentEpisodes.next;
      _episode.previous = adjacentEpisodes.previous;
      _episode.nextStatus = adjacentEpisodes.nextStatus;
    });
    _primeNextEpisodePlaybackMetadata(adjacentEpisodes.next);
    _lookUpCopiesOfNext(adjacentEpisodes.next);
  }

  /// Whether advancing to the queue's [episode] may play another library's
  /// copy of it. Only a plain series queue qualifies: playlists, collections,
  /// launcher play queues and shuffle keep their own items, and so do Watch
  /// Together, offline playback and Live TV.
  bool _mayPlayCopyOf(MediaItem episode) {
    if (!mounted || _offlineLibraryMode || widget.isLive || !episode.isEpisode) return false;
    if (_watchTogetherRoom() != null) return false;
    final playbackState = context.read<PlaybackStateProvider?>();
    return playbackState != null &&
        playbackState.isQueueActive &&
        !playbackState.isShuffleActive &&
        episode.grandparentId != null &&
        playbackState.shuffleContextKey == episode.grandparentId;
  }

  /// Re-issues the next episode's copy lookup once the current item nears its
  /// end — the Play Next prompt, a credits marker, or [_nearEndCopyLookupLead]
  /// left, whichever comes first — once per item. The lookup made when next
  /// committed is older than the resolver's TTL by the end of a typical
  /// episode, and the advance only reads what is cached.
  void _refreshCopiesOfNextNearEnd() {
    final next = _episode.next;
    if (next == null || _episode.nearEndCopyLookupKey == next.globalKey) return;
    if (!_mayPlayCopyOf(next)) return;
    _episode.nearEndCopyLookupKey = next.globalKey;
    _lookUpCopiesOfNext(next);
  }

  /// [_refreshCopiesOfNextNearEnd] on a position tick within
  /// [_nearEndCopyLookupLead] of the end of a known duration.
  void _refreshCopiesOfNextForPosition(Duration position, Duration duration) {
    if (widget.isLive || duration <= Duration.zero || duration - position > _nearEndCopyLookupLead) return;
    _refreshCopiesOfNextNearEnd();
  }

  /// Warms the profile's copy lookup for the next episode, so the advance
  /// can read it without waiting ([_bestCopyOf]).
  void _lookUpCopiesOfNext(MediaItem? next) {
    if (next == null || !_mayPlayCopyOf(next)) return;
    final resolver = context.read<CopyResolver?>();
    if (resolver == null) return;
    unawaited(
      resolver
          .episodeCopiesOf(next)
          .then<void>(
            (_) {},
            onError: (Object e, StackTrace st) =>
                appLogger.w('Copy lookup for the next episode failed', error: e, stackTrace: st),
          ),
    );
  }

  /// The copy to play for the queue's [episode] — the remembered pick, then
  /// the ranking — from what the lookup already holds, or null to play
  /// [episode] itself. The copy carries the furthest progress across copies
  /// as its `viewOffsetMs`, which the reload starts from. [pickSignature] is
  /// the pick's version when the pick chose this copy.
  ///
  /// Never waits on a server: an unanswered lookup plays the queue's item. A
  /// completed download of [episode] plays from disk instead, as plain Play
  /// does.
  Future<({MediaItem item, String? pickSignature})?> _bestCopyOf(MediaItem episode) async {
    try {
      if (!_mayPlayCopyOf(episode)) return null;
      final resolved = context.read<CopyResolver?>()?.peek(episode);
      if (resolved == null) return null;
      final pick = context.read<CopyPickStore?>()?.read(resolved.aliases)?.ref;
      final downloads = context.read<DownloadProvider?>();
      if (downloads != null && await downloads.getCompletedDownload(episode.globalKey) != null) return null;
      if (!mounted) return null;
      var chosen = chooseTarget(resolved.copies, pick);
      final pickChoseIt = pick != null && (copyPickKey(chosen) == pick.key || chosen.libraryGlobalKey == pick.lib);
      final resumeMs = furthestResumeOffsetMs(chosen, resolved.copies) ?? chosen.viewOffsetMs;
      if (resumeMs != chosen.viewOffsetMs) chosen = chosen.copyWith(viewOffsetMs: resumeMs);
      return (item: chosen, pickSignature: pickChoseIt ? pick.sig : null);
    } catch (e, st) {
      appLogger.w('Could not choose a copy of the next episode', error: e, stackTrace: st);
      return null;
    }
  }

  /// Best-effort prefetch of the next episode's full metadata row into the
  /// API cache while the current episode plays (#1867).
  ///
  /// Adjacency comes from queue containers, so the per-item metadata row
  /// (Plex `/library/metadata/{id}`, Jellyfin `/Users/{uid}/Items/{id}`) is
  /// cold at the exact moment the transition needs it. Both backends'
  /// [MediaServerClient.fetchItem] fetch network-first and write that same
  /// row — the one playback initialization falls back to when the server is
  /// transiently unreachable — so a warm row turns a connectivity blip at
  /// the transition into a normal start instead of a failed advance.
  ///
  /// Documented best-effort: the transition path performs its own fetch and
  /// error handling, so a failed prime costs nothing.
  void _primeNextEpisodePlaybackMetadata(MediaItem? next) {
    if (next == null || _offlineLibraryMode || !mounted) return;
    if (_episode.primedNextGlobalKey == next.globalKey) return;
    final client = context.tryGetMediaClientForServer(serverIdOrNull(next.serverId));
    if (client == null) return;
    _episode.primedNextGlobalKey = next.globalKey;
    unawaited(() async {
      try {
        await client.fetchItem(next.id);
      } catch (e) {
        appLogger.d('Next-episode metadata prime failed', error: e);
      }
    }());
  }
}
