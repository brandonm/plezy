import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../services/copy_resolver.dart';
import 'debouncer.dart';

/// Looks up the copies of the movie or episode a row has focused once focus
/// rests on it for [delay], so Play pressed from the row (Continue Watching
/// plays an episode directly) finds them cached instead of running out its
/// wait on a cold lookup. Call [dispose] from the owning State's dispose.
class CopyWarmer {
  CopyWarmer(this._context);

  /// As long as the detail page waits before its own lookup: focus passing
  /// across a row asks nothing.
  static const delay = Duration(milliseconds: 350);

  final BuildContext _context;
  final Debouncer _debouncer = Debouncer(delay);

  void focused(MediaItem item) {
    if (item.kind != MediaKind.movie && item.kind != MediaKind.episode) {
      _debouncer.cancel();
      return;
    }
    _debouncer.run(() {
      if (!_context.mounted) return;
      final resolver = _context.read<CopyResolver?>();
      if (resolver == null || resolver.isDisposed || resolver.peek(item) != null) return;
      // Answers the opened item alone on failure, which it has logged.
      unawaited(resolver.copiesOf(item));
    });
  }

  void dispose() => _debouncer.dispose();
}
