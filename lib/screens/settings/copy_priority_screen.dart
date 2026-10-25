import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/dpad_navigator.dart';
import '../../focus/dpad_reorder_mixin.dart';
import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../providers/copy_priority_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../utils/app_logger.dart';
import '../../utils/content_utils.dart';
import '../../widgets/app_icon.dart';

/// Whether [library] holds video that Play can start: movies or shows, or a
/// mixed library whose root browse includes either.
bool _isVideoLibrary(MediaLibrary library) => switch (library.kind) {
  MediaKind.movie || MediaKind.show => true,
  MediaKind.unknown => library.defaultBrowseKinds.any((k) => k == MediaKind.movie || k == MediaKind.show),
  _ => false,
};

/// [ranked] with the keys of [stored] the screen doesn't show (a server offline
/// or not loaded yet) kept in place: each right after the stored key before it
/// that is still ranked, or at the front when none is. Only the removal of
/// their server deletes them.
List<String> _keepingHidden(List<String> ranked, Set<String> shown, List<String> stored) {
  final stillRanked = ranked.toSet();
  final front = <String>[];
  final after = <String, List<String>>{};
  String? anchor;
  for (final key in stored) {
    if (stillRanked.contains(key)) {
      anchor = key;
    } else if (!shown.contains(key)) {
      (anchor == null ? front : after.putIfAbsent(anchor, () => [])).add(key);
    }
  }
  return [
    ...front,
    for (final key in ranked) ...[key, ...?after[key]],
  ];
}

/// Settings → Playback → Copy priority: ranks libraries across servers so Play
/// starts the best-ranked copy of a title. Libraries the user has not ranked
/// sit below a divider and are ordered by resolution at play time. The
/// divider shows even when every library is ranked, at the end, so a row can
/// be moved below it.
class CopyPriorityScreen extends StatefulWidget {
  const CopyPriorityScreen({super.key});

  @override
  State<CopyPriorityScreen> createState() => _CopyPriorityScreenState();
}

class _CopyPriorityScreenState extends State<CopyPriorityScreen>
    with DpadReorderListMixin<MediaLibrary, CopyPriorityScreen> {
  /// Marks the unranked divider while a drag reorders the display list.
  static const Object _divider = Object();

  late final LibrariesProvider _libraries;
  late final CopyPriorityProvider _priority;

  /// Ranked libraries first, then the unranked ones. The first [_rankedCount]
  /// are ranked.
  List<MediaLibrary> _items = [];
  int _rankedCount = 0;

  /// Whether the row being moved started in the ranked part, captured when
  /// move mode begins so a crossing of the divider can be told from a move
  /// within one part.
  bool? _moveStartedRanked;

  /// Where the row being moved started, captured with [_moveStartedRanked].
  int? _moveStartIndex;

  /// Whether the row being moved, last of all and ranked when the move began,
  /// was carried down across the divider at the end. No row sits below it to
  /// swap with, so the crossing is a step of its own.
  bool _crossedEndDivider = false;

  /// Whether the row being moved, first of all with nothing ranked, was
  /// carried up across the divider at the top: the mirror of
  /// [_crossedEndDivider].
  bool _crossedTopDivider = false;

  final FocusNode _listFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  List<MediaLibrary> get reorderItems => _items;

  @override
  set reorderItems(List<MediaLibrary> value) => _items = value;

  @override
  int get lastReorderColumn => 0;

  @override
  ScrollController? get reorderScrollController => _scrollController;

  @override
  void initState() {
    super.initState();
    _libraries = context.read<LibrariesProvider>();
    _priority = context.read<CopyPriorityProvider>();
    _libraries.addListener(_syncFromProviders);
    _priority.addListener(_syncFromProviders);
    _priority.ensureInitialized().then((_) => _syncFromProviders());
    _syncFromProviders(notify: false);
  }

  @override
  void dispose() {
    _libraries.removeListener(_syncFromProviders);
    _priority.removeListener(_syncFromProviders);
    _listFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Rebuilds the rows from the providers: only libraries that exist now are
  /// shown. Stored keys for the others stay out of the list, and stay stored
  /// when it is saved ([_keepingHidden]).
  void _syncFromProviders({bool notify = true}) {
    if (!mounted || movingIndex != null) return;
    final present = {for (final l in _libraries.libraries.where(_isVideoLibrary)) l.globalKey: l};
    final ranked = <MediaLibrary>[];
    for (final key in _priority.priority) {
      final library = present.remove(key);
      if (library != null) ranked.add(library);
    }
    final next = [...ranked, ...present.values];
    void apply() {
      _items = next;
      _rankedCount = ranked.length;
      if (focusedIndex >= _items.length) focusedIndex = _items.isEmpty ? 0 : _items.length - 1;
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  /// Ranked count if the move in progress were confirmed now: a row carried
  /// across the divider changes sides, and the divider follows it.
  int get _effectiveRankedCount {
    final moving = movingIndex;
    final startedRanked = _moveStartedRanked;
    if (moving == null || startedRanked == null) return _rankedCount;
    if (!startedRanked && (moving < _rankedCount || _crossedTopDivider)) return _rankedCount + 1;
    if (startedRanked && (moving >= _rankedCount || _crossedEndDivider)) return _rankedCount - 1;
    return _rankedCount;
  }

  void _save(List<MediaLibrary> items, int rankedCount) {
    _items = items;
    _rankedCount = rankedCount;
    final ranked = [for (final l in items.take(rankedCount)) l.globalKey];
    final shown = {for (final l in items) l.globalKey};
    unawaited(
      _priority.setPriority(_keepingHidden(ranked, shown, _priority.priority)).catchError((Object e, StackTrace st) {
        appLogger.w('Could not save the copy priority', error: e, stackTrace: st);
      }),
    );
  }

  /// An unranked row moved within the unranked part keeps the place it was
  /// put in: it and every row above it are ranked, so the order on screen is
  /// the order saved.
  @override
  void onReorderMoveConfirmed() {
    final moving = movingIndex;
    final count = _effectiveRankedCount;
    final movedWithinUnranked =
        moving != null && _moveStartedRanked == false && moving >= count && moving != _moveStartIndex;
    _save(_items, movedWithinUnranked ? moving + 1 : count);
  }

  /// With nothing ranked, the first row crosses the divider at the top in
  /// place, UP to rank it and DOWN to unrank it again. The last row crosses
  /// the divider at the end in place, DOWN to unrank it and UP to rank it
  /// again. Every other key goes to [handleReorderKeyEvent].
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final moving = movingIndex;
    if (moving == 0 && _rankedCount == 0 && event.isActionable) {
      final key = event.logicalKey;
      if (key.isUpKey && !_crossedTopDivider) {
        setState(() => _crossedTopDivider = true);
        return KeyEventResult.handled;
      }
      if (key.isDownKey && _crossedTopDivider) {
        setState(() => _crossedTopDivider = false);
        return KeyEventResult.handled;
      }
    }
    if (moving != null && moving == _items.length - 1 && event.isActionable) {
      final key = event.logicalKey;
      if (key.isDownKey && moving < _effectiveRankedCount) {
        setState(() => _crossedEndDivider = true);
        return KeyEventResult.handled;
      }
      if (key.isUpKey && _crossedEndDivider) {
        setState(() => _crossedEndDivider = false);
        return KeyEventResult.handled;
      }
    }
    return handleReorderKeyEvent(node, event);
  }

  @override
  void onReorderColumnActivated(int column, int index) {}

  /// Touch drag. [oldIndex] and [newIndex] address the display list, which has
  /// the divider in it; dropping a row on the other side of the divider ranks
  /// or unranks it, and moving one within the unranked part ranks it as
  /// [onReorderMoveConfirmed] does.
  void _onDragReorder(int oldIndex, int newIndex) {
    final display = <Object>[..._items.take(_rankedCount), _divider, ..._items.skip(_rankedCount)];
    final moved = display.removeAt(oldIndex);
    display.insert(newIndex, moved);
    final dividerAt = display.indexOf(_divider);
    final items = display.whereType<MediaLibrary>().toList();
    final movedAt = display.indexOf(moved);
    final movedWithinUnranked = oldIndex > _rankedCount && movedAt > dividerAt && movedAt != oldIndex;
    setState(() => _save(items, movedWithinUnranked ? movedAt : dividerAt));
  }

  @override
  Widget build(BuildContext context) {
    // Track where the row being moved started; the first build of a move is
    // before any swap, so its index is still the starting one.
    if (movingIndex == null) {
      _moveStartedRanked = null;
      _moveStartIndex = null;
      _crossedEndDivider = false;
      _crossedTopDivider = false;
    } else {
      _moveStartedRanked ??= movingIndex! < _rankedCount;
      _moveStartIndex ??= movingIndex;
    }

    final count = _effectiveRankedCount;
    final isKeyboardMode = InputModeTracker.isKeyboardMode(context);
    final rows = <Widget>[];
    for (var i = 0; i < _items.length; i++) {
      final isFocused = isKeyboardMode && i == focusedIndex;
      rows.add(_buildRow(_items[i], i, count, isFocused: isFocused, isMoving: i == movingIndex));
    }
    if (rows.isNotEmpty) rows.insert(count, _buildDivider());

    return PopScope(
      // On Android TV the back key is handled by the reorder handler; letting
      // the system back through as well would pop twice.
      canPop: !InputModeTracker.shouldBlockSystemBack(context),
      // ignore: no-empty-block - required callback, blocks system back on Android TV
      onPopInvokedWithResult: (didPop, result) {},
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.settings.copyPriority),
          leading: BackButton(onPressed: () => Navigator.pop(context)),
        ),
        body: Focus(
          focusNode: _listFocusNode,
          descendantsAreFocusable: false,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: ReorderableListView(
            scrollController: _scrollController,
            onReorderItem: _onDragReorder,
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: rows,
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('copy-priority-unranked-divider'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Text(t.settings.copyPriorityUnranked, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          const SizedBox(width: 12),
          Expanded(child: Divider(color: scheme.outlineVariant, height: 1)),
        ],
      ),
    );
  }

  /// [displayIndex] is [index] plus the divider when the row sits below it,
  /// which is what the drag listener addresses.
  Widget _buildRow(
    MediaLibrary library,
    int index,
    int rankedCount, {
    required bool isFocused,
    required bool isMoving,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final displayIndex = index >= rankedCount ? index + 1 : index;
    return ListTile(
      key: ValueKey(library.globalKey),
      tileColor: isMoving
          ? scheme.primaryContainer
          : isFocused
          ? scheme.surfaceContainerHighest
          : null,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: displayIndex,
            child: AppIcon(
              isMoving ? Symbols.swap_vert_rounded : Symbols.drag_indicator_rounded,
              fill: 1,
              color: isMoving ? scheme.primary : IconTheme.of(context).color?.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 8),
          AppIcon(ContentTypeHelper.getLibraryIcon(library.kind.id), fill: 1),
        ],
      ),
      title: Text(library.serverName != null ? '${library.serverName} · ${library.title}' : library.title),
    );
  }
}
