import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/copy_resolver.dart';
import 'package:plezy/utils/copy_warmer.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';

/// Records the lookups asked of it; [cached] answers [peek].
class _Resolver implements CopyResolver {
  final asked = <String>[];
  final cached = <String>{};

  @override
  bool get isDisposed => false;

  @override
  ResolvedCopies? peek(MediaItem item) =>
      cached.contains(item.globalKey) ? ResolvedCopies(copies: [item], aliases: const {}) : null;

  @override
  Future<ResolvedCopies> copiesOf(MediaItem item, {AbortController? abort}) async {
    asked.add(item.globalKey);
    return ResolvedCopies(copies: [item], aliases: const {});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Resolver resolver;
  late CopyWarmer warmer;

  Future<void> pump(WidgetTester tester, {bool withResolver = true}) async {
    resolver = _Resolver();
    await tester.pumpWidget(
      Provider<CopyResolver?>.value(
        value: withResolver ? resolver : null,
        child: Builder(
          builder: (context) {
            warmer = CopyWarmer(context);
            return const SizedBox();
          },
        ),
      ),
    );
    addTearDown(() => warmer.dispose());
  }

  final movie = testMediaItem(id: 'm', serverId: 's1');
  final episode = testMediaItem(id: 'e', serverId: 's1', kind: MediaKind.episode);

  testWidgets('looks up a focused movie once focus rests on it', (tester) async {
    await pump(tester);

    warmer.focused(movie);
    await tester.pump(CopyWarmer.delay - const Duration(milliseconds: 1));
    expect(resolver.asked, isEmpty, reason: 'not before the delay');
    await tester.pump(const Duration(milliseconds: 1));

    expect(resolver.asked, [movie.globalKey]);
  });

  testWidgets('focus passing over items looks up only where it stops', (tester) async {
    await pump(tester);

    warmer.focused(movie);
    await tester.pump(const Duration(milliseconds: 100));
    warmer.focused(episode);
    await tester.pump(CopyWarmer.delay);

    expect(resolver.asked, [episode.globalKey]);
  });

  testWidgets('a show or season is not looked up, and cancels a pending lookup', (tester) async {
    await pump(tester);

    warmer.focused(movie);
    warmer.focused(testMediaItem(id: 'sh', serverId: 's1', kind: MediaKind.show));
    warmer.focused(testMediaItem(id: 'se', serverId: 's1', kind: MediaKind.season));
    await tester.pump(CopyWarmer.delay * 2);

    expect(resolver.asked, isEmpty);
  });

  testWidgets('copies already cached are not looked up again', (tester) async {
    await pump(tester);
    resolver.cached.add(movie.globalKey);

    warmer.focused(movie);
    await tester.pump(CopyWarmer.delay);

    expect(resolver.asked, isEmpty);
  });

  testWidgets('dispose drops a pending lookup', (tester) async {
    await pump(tester);

    warmer.focused(movie);
    warmer.dispose();
    await tester.pump(CopyWarmer.delay * 2);

    expect(resolver.asked, isEmpty);
  });

  testWidgets('without a resolver (no profile session) nothing happens', (tester) async {
    await pump(tester, withResolver: false);

    warmer.focused(movie);
    await tester.pump(CopyWarmer.delay);

    expect(resolver.asked, isEmpty);
  });
}
