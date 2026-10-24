part of '../media_detail_screen.dart';

/// The copies of what Play starts, across the profile's servers (copy
/// priority, spec §3): Play's label names the copy it will start, the Play
/// Version picker lists every copy's versions, and a show page lists its
/// other copies under "Also in".
///
/// The playback target is followed from build, like the track probe: on TV it
/// moves with rail focus. A new target retires the held answer, aborts the
/// lookup in flight and starts another after [_copyLookupDelay], so D-pad
/// scrubbing doesn't ask for every episode it passes. [_copyGeneration] drops
/// an answer that lands after its target was replaced.
extension _MediaDetailCopyTargets on _MediaDetailScreenState {
  static const _copyLookupDelay = Duration(milliseconds: 350);

  /// The held copies of [target] and the copy Play starts among them, or null
  /// while unknown. A [target] other than the last one seen retires the
  /// answer and schedules a lookup for it.
  _TargetCopies? _copiesForTarget(MediaItem? target) {
    if (target?.globalKey != _copiesTargetKey) {
      _retargetCopies(target);
      return null;
    }
    return _targetCopies.value;
  }

  void _retargetCopies(MediaItem? target) {
    _copiesTargetKey = target?.globalKey;
    _copiesTargetItem = target;
    final generation = ++_copyGeneration;
    _copiesTimer?.cancel();
    _copiesTimer = null;
    _copiesAbort?.abort();
    _copiesAbort = null;
    final resolver = target == null || widget.isOffline || !(target.isMovie || target.isEpisode)
        ? null
        : context.read<CopyResolver?>();
    // Called from build: the notifier's listeners rebuild, so it changes after.
    scheduleMicrotask(() {
      if (generation != _copyGeneration || !_canUseDetail) return;
      final warm = target == null ? null : resolver?.peek(target);
      _targetCopies.value = warm == null ? null : _withPlayTarget(warm);
      if (warm != null || resolver == null || target == null) return;
      _copiesTimer = Timer(_copyLookupDelay, () => unawaited(_resolveTargetCopies(resolver, target, generation)));
    });
  }

  Future<void> _resolveTargetCopies(CopyResolver resolver, MediaItem target, int generation) async {
    if (generation != _copyGeneration || !_canUseDetail) return;
    final priority = context.read<CopyPriorityProvider?>();
    // Fresh per request: aborted when the target changes or the page goes.
    final abort = _copiesAbort = AbortController();
    try {
      // Before the first read, or the copies sort by resolution alone.
      await priority?.ensureInitialized();
      final copies = await resolver.copiesOf(target, abort: abort);
      // An answer for a target the page has since moved off.
      if (generation != _copyGeneration || !_canUseDetail) return;
      _targetCopies.value = _withPlayTarget(copies);
    } catch (e) {
      if (!abort.isAborted) appLogger.w('Copy lookup failed for ${target.globalKey}', error: e);
    } finally {
      if (identical(_copiesAbort, abort)) _copiesAbort = null;
    }
  }

  /// [copies] with the copy plain Play starts: the remembered pick, else the
  /// best-ranked one.
  _TargetCopies _withPlayTarget(ResolvedCopies copies) {
    final pick = context.read<CopyPickStore?>()?.read(copies.aliases);
    return (copies: copies, target: chooseTarget(copies.copies, pick?.ref));
  }

  /// Chooses again when a pick is written or cleared (from any Play Version
  /// entry: the split segment, the ⋮ menu, an episode card's menu) or the
  /// priority order changes while the page is open.
  void _initCopyRankingListeners() {
    final picks = context.read<CopyPickStore?>();
    final priority = context.read<CopyPriorityProvider?>();
    // Deferred: a notification may come mid-build, and the notifiers rebuild.
    void onChanged() => scheduleMicrotask(_rechooseCopyTargets);
    if (picks != null) bindListenable(picks.changes, onChanged);
    if (priority != null) bindListenable(priority, onChanged);
  }

  /// The held copies chosen among again, with no new lookup: re-read from
  /// the resolver's cache when it is warm, else re-sorted by the current
  /// priority. The "Also in" row follows the priority too.
  void _rechooseCopyTargets() {
    if (!_canUseDetail) return;
    final resolver = context.read<CopyResolver?>();
    final held = _targetCopies.value;
    final target = _copiesTargetItem;
    if (held != null && target != null) {
      _targetCopies.value = _withPlayTarget(resolver?.peek(target) ?? _reranked(held.copies));
    }
    final alsoIn = _alsoInCopies.value;
    if (alsoIn.length > 1) _alsoInCopies.value = _rerankedItems(alsoIn);
  }

  ResolvedCopies _reranked(ResolvedCopies copies) => ResolvedCopies(
    copies: _rerankedItems(copies.copies),
    failedServerIds: copies.failedServerIds,
    cancelledServerIds: copies.cancelledServerIds,
    unqueriedServerIds: copies.unqueriedServerIds,
    aliases: copies.aliases,
  );

  List<MediaItem> _rerankedItems(List<MediaItem> copies) {
    final priority = context.read<CopyPriorityProvider?>();
    if (priority == null) return copies;
    return [...copies]..sort(compareCopiesByPriority(priority.priority));
  }

  /// The copy Play's label names for [opened], or null for plain Play: only
  /// once copies are known, and only when Play leaves [opened] or there is
  /// more than one copy to choose from.
  String? _copyTargetLabel(MediaItem? opened, _TargetCopies? held) {
    if (opened == null || held == null) return null;
    if (held.target.globalKey == opened.globalKey && held.copies.copies.length < 2) return null;
    return copyLibraryName(held.target);
  }

  /// Whether the split "Play Version" segment shows for [target]: across
  /// servers, when its copies hold more than one version in all; for a target
  /// found alone (or not looked up yet), when it carries a choice of its own
  /// and its server is reachable (offline, at most one version can play; see
  /// #1440).
  bool _offersVersionChoice(BuildContext context, MediaItem? target, ResolvedCopies? copies) {
    if (widget.isOffline || target == null || !(target.isMovie || target.isEpisode)) return false;
    if (copies != null && !isOpenedAlone(copies, target)) return copyVersionCount(copies) > 1;
    final serverId = serverIdOrNull(target.serverId);
    return (target.mediaVersions?.length ?? 0) > 1 &&
        serverId != null &&
        context.read<MultiServerProvider>().serverManager.isClientOnline(serverId);
  }

  /// Looks up a show's copies once, for the "Also in" row.
  void _initAlsoIn() {
    if (widget.isOffline || !_metadata.isShow) return;
    final resolver = context.read<CopyResolver?>();
    if (resolver == null) return;
    unawaited(_resolveAlsoIn(resolver, _metadata, context.read<CopyPriorityProvider?>()));
  }

  Future<void> _resolveAlsoIn(CopyResolver resolver, MediaItem show, CopyPriorityProvider? priority) async {
    final abort = _alsoInAbort = AbortController();
    try {
      await priority?.ensureInitialized();
      final copies = await resolver.copiesOf(show, abort: abort);
      if (!_canUseDetail) return;
      _alsoInCopies.value = [
        for (final copy in copies.copies)
          if (copy.globalKey != show.globalKey) copy,
      ];
    } catch (e) {
      if (!abort.isAborted) appLogger.w('Show copy lookup failed for ${show.globalKey}', error: e);
    } finally {
      if (identical(_alsoInAbort, abort)) _alsoInAbort = null;
    }
  }

  /// Focuses the "Also in" row; false when the page shows none.
  bool _focusAlsoInRow() {
    if (_alsoInCopies.value.isEmpty || _alsoInFocusNode.context == null) return false;
    _alsoInFocusNode.requestFocus();
    if (!PlatformDetector.isTV()) _scrollSectionIntoView(_alsoInSectionKey);
    return true;
  }

  /// "Also in" and a chip per other copy of the show, best first; selecting
  /// one opens that copy's show page. UP and DOWN leave the row by
  /// [onNavigateUp] and [onNavigateDown]; LEFT and RIGHT move between chips.
  Widget _buildAlsoInRow(
    BuildContext context,
    List<MediaItem> copies, {
    required bool isTv,
    required double scale,
    required VoidCallback onNavigateUp,
    required VoidCallback onNavigateDown,
    Color? labelColor,
  }) {
    final fontSize = isTv ? 16 * scale : 13.0;
    final gap = isTv ? 8 * scale : 8.0;
    return Row(
      key: _alsoInSectionKey,
      children: [
        Text(
          t.mediaDetail.alsoIn,
          style: TextStyle(
            color: labelColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: fontSize,
            fontWeight: .w600,
          ),
        ),
        SizedBox(width: gap),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                for (final (index, copy) in copies.indexed) ...[
                  if (index > 0) SizedBox(width: gap),
                  _AlsoInChip(
                    focusNode: index == 0 ? _alsoInFocusNode : null,
                    label: copyLibraryName(copy) ?? copy.displayTitle,
                    fontSize: fontSize,
                    padding: isTv
                        ? EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 6 * scale)
                        : _HeroChips.padding,
                    onSelect: () => unawaited(navigateToMediaItemDetails(context, copy)),
                    onNavigateUp: onNavigateUp,
                    onNavigateDown: onNavigateDown,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A playback target's copies and the copy Play starts among them.
typedef _TargetCopies = ({ResolvedCopies copies, MediaItem target});

/// One copy in the "Also in" row: a chip that opens the copy's show page.
class _AlsoInChip extends StatefulWidget {
  const _AlsoInChip({
    this.focusNode,
    required this.label,
    required this.fontSize,
    required this.padding,
    required this.onSelect,
    required this.onNavigateUp,
    required this.onNavigateDown,
  });

  final FocusNode? focusNode;
  final String label;
  final double fontSize;
  final EdgeInsetsGeometry padding;
  final VoidCallback onSelect;
  final VoidCallback onNavigateUp;
  final VoidCallback onNavigateDown;

  @override
  State<_AlsoInChip> createState() => _AlsoInChipState();
}

class _AlsoInChipState extends State<_AlsoInChip> {
  FocusNode? _ownNode;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode(debugLabel: 'also_in_chip'));

  @override
  void dispose() {
    _ownNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _node,
      builder: (context, _) {
        final colorScheme = Theme.of(context).colorScheme;
        final showFocus = _node.hasFocus && InputModeTracker.isKeyboardMode(context);
        final background = showFocus
            ? colorScheme.inverseSurface
            : colorScheme.secondaryContainer.withValues(alpha: 0.8);
        final foreground = showFocus ? colorScheme.onInverseSurface : colorScheme.onSecondaryContainer;
        return FocusableWrapper(
          focusNode: _node,
          onSelect: widget.onSelect,
          onNavigateUp: widget.onNavigateUp,
          onNavigateDown: widget.onNavigateDown,
          borderRadius: 100,
          disableScale: true,
          useBackgroundFocus: true,
          autoScroll: false,
          child: GestureDetector(
            onTap: widget.onSelect,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              padding: widget.padding,
              decoration: BoxDecoration(color: background, borderRadius: _HeroChips.radius),
              child: Text(
                widget.label,
                maxLines: 1,
                style: TextStyle(color: foreground, fontSize: widget.fontSize, fontWeight: .w500),
              ),
            ),
          ),
        );
      },
    );
  }
}
