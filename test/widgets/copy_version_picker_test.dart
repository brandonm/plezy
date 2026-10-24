import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/services/copy_resolver.dart';
import 'package:plezy/widgets/copy_version_picker.dart';

import '../test_helpers/media_items.dart';

/// The grouped Play Version picker (copy priority, spec §3/§4): one row per
/// version, grouped by copy in the resolver's best-first order, and a reset
/// row when a remembered pick exists.
void main() {
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.en));

  const v4kA = MediaVersion(id: '4k-a', videoResolution: '4k', videoCodec: 'hevc', container: 'mkv');
  const v4kB = MediaVersion(id: '4k-b', videoResolution: '4k', videoCodec: 'h264', container: 'mp4');
  const vHd = MediaVersion(id: 'hd', videoResolution: '1080', videoCodec: 'h264', container: 'mp4');
  final silo = _movie('m-silo', 'silo', 'Silo', 'Movies 4K', versions: const [v4kA, v4kB]);
  final plex = _movie('m-plex', 'plex', 'Plex', 'Movies', versions: const [vHd]);
  // A copy whose version list the server didn't send still plays one version.
  final jelly = _movie('m-jelly', 'jelly', 'Jelly', 'Films');
  final copies = ResolvedCopies(copies: [silo, plex, jelly], aliases: const {'movie|tmdb:1'});

  testWidgets('picker groups versions by copy, best copy first, rows "Server · Library · <displayLabel>"', (
    tester,
  ) async {
    final picker = await _Picker.pump(tester, copies, hasPick: false);

    final rows = [
      'Silo · Movies 4K · ${v4kA.displayLabel}',
      'Silo · Movies 4K · ${v4kB.displayLabel}',
      'Plex · Movies · ${vHd.displayLabel}',
      'Jelly · Films',
    ];
    for (final row in rows) {
      expect(picker.row(row), findsOneWidget, reason: row);
    }
    expect(picker.row(t.mediaMenu.usePriorityOrder), findsNothing, reason: 'no pick to reset');
    final tops = [for (final row in rows) tester.getTopLeft(picker.row(row)).dy];
    expect(tops, orderedEquals([...tops]..sort()), reason: "best copy first, each copy's versions together");

    await tester.tap(picker.row(rows[1]));
    await tester.pumpAndSettle();

    expect(picker.result?.copy, same(silo));
    expect(picker.result?.versionIndex, 1);
    expect(picker.result?.reset, isFalse);
  });

  testWidgets('a copy without a version list answers its default version', (tester) async {
    final picker = await _Picker.pump(tester, copies, hasPick: false);

    await tester.tap(picker.row('Jelly · Films'));
    await tester.pumpAndSettle();

    expect(picker.result?.copy, same(jelly));
    expect(picker.result?.versionIndex, 0);
    expect(picker.result?.reset, isFalse);
  });

  testWidgets('"Use priority order" is the first row when a pick exists, and answers a reset', (tester) async {
    final picker = await _Picker.pump(tester, copies, hasPick: true);

    final reset = picker.row(t.mediaMenu.usePriorityOrder);
    expect(reset, findsOneWidget);
    expect(
      tester.getTopLeft(reset).dy,
      lessThan(tester.getTopLeft(picker.row('Silo · Movies 4K · ${v4kA.displayLabel}')).dy),
    );

    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(picker.result?.reset, isTrue);
  });

  test('a copy is named by its server and library, or its server alone', () {
    expect(copyLibraryName(silo), 'Silo Movies 4K');
    expect(copyLibraryName(_movie('x', 'silo', 'Silo', null)), 'Silo');
  });

  test('version count: a copy without a version list counts as one', () {
    expect(copyVersionCount(copies), 4);
    expect(copyVersionCount(ResolvedCopies(copies: [jelly])), 1);
  });
}

MediaItem _movie(String id, String serverId, String serverName, String? libraryTitle, {List<MediaVersion>? versions}) =>
    testMediaItem(
      id: id,
      backend: MediaBackend.jellyfin,
      kind: MediaKind.movie,
      title: 'The Movie',
      serverId: serverId,
      serverName: serverName,
      libraryId: libraryTitle == null ? null : 'lib-$id',
      libraryTitle: libraryTitle,
      mediaVersions: versions,
    );

class _Picker {
  CopyVersionChoice? result;

  Finder row(String label) => find.descendant(of: find.byType(Dialog), matching: find.text(label));

  static Future<_Picker> pump(WidgetTester tester, ResolvedCopies copies, {required bool hasPick}) async {
    final picker = _Picker();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => picker.result = await showCopyVersionPicker(context, copies, hasPick: hasPick),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text(t.mediaMenu.playVersion), findsOneWidget);
    return picker;
  }
}
