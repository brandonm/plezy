import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/providers/copy_priority_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/screens/settings/copy_priority_screen.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

MediaLibrary _lib(
  String server,
  String id,
  String title, {
  MediaKind kind = MediaKind.movie,
  List<MediaKind>? browse,
}) => MediaLibrary(
  id: id,
  backend: MediaBackend.plex,
  title: title,
  kind: kind,
  defaultBrowseKinds: browse ?? const [],
  serverId: server,
  serverName: 'Srv$server',
);

class _FixtureLibraries extends LibrariesProvider {
  _FixtureLibraries(this.libraries);

  @override
  final List<MediaLibrary> libraries;
}

Future<CopyPriorityProvider> _pump(
  WidgetTester tester,
  List<MediaLibrary> libraries, {
  List<String> stored = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final storage = await StorageService.getInstance();
  if (stored.isNotEmpty) await storage.saveCopyPriorityForProfile('p1', stored);
  final priority = CopyPriorityProvider(storageService: storage, profileId: 'p1');
  await priority.ensureInitialized();
  addTearDown(priority.dispose);
  final libs = _FixtureLibraries(libraries);
  addTearDown(libs.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LibrariesProvider>.value(value: libs),
        ChangeNotifierProvider<CopyPriorityProvider>.value(value: priority),
      ],
      child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const CopyPriorityScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return priority;
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('lists movie, show and mixed-video libraries; excludes music and photo', (tester) async {
    await _pump(tester, [
      _lib('1', 'm', 'Movies'),
      _lib('1', 's', 'Shows', kind: MediaKind.show),
      _lib('1', 'x', 'Mixed', kind: MediaKind.unknown, browse: [MediaKind.movie, MediaKind.show]),
      _lib('1', 'mm', 'MixedMusic', kind: MediaKind.unknown, browse: [MediaKind.album]),
      _lib('1', 'a', 'Music', kind: MediaKind.artist),
      _lib('1', 'p', 'Photos', kind: MediaKind.photo),
    ]);

    expect(find.text('Srv1 · Movies'), findsOneWidget);
    expect(find.text('Srv1 · Shows'), findsOneWidget);
    expect(find.text('Srv1 · Mixed'), findsOneWidget);
    expect(find.textContaining('MixedMusic'), findsNothing);
    expect(find.text('Srv1 · Music'), findsNothing);
    expect(find.textContaining('Photos'), findsNothing);
  });

  testWidgets('ranked rows first, then the unranked divider', (tester) async {
    await _pump(tester, [_lib('1', 'a', 'A'), _lib('1', 'b', 'B'), _lib('2', 'c', 'C')], stored: ['2:c', '1:a']);

    final divider = find.text('Unranked (by resolution)');
    expect(divider, findsOneWidget);
    final c = tester.getTopLeft(find.text('Srv2 · C')).dy;
    final a = tester.getTopLeft(find.text('Srv1 · A')).dy;
    final d = tester.getTopLeft(divider).dy;
    final b = tester.getTopLeft(find.text('Srv1 · B')).dy;
    expect(c < a && a < d && d < b, isTrue, reason: 'order should be C, A, divider, B');
  });

  testWidgets('D-pad reorder persists the new order', (tester) async {
    final priority = await _pump(tester, [_lib('1', 'a', 'A'), _lib('1', 'b', 'B')], stored: ['1:a', '1:b']);

    await _key(tester, LogicalKeyboardKey.arrowDown); // cursor to B
    await _key(tester, LogicalKeyboardKey.select); // enter move mode
    await _key(tester, LogicalKeyboardKey.arrowUp); // move B above A
    await _key(tester, LogicalKeyboardKey.select); // confirm
    await tester.pumpAndSettle();

    expect(priority.priority, ['1:b', '1:a']);
    final b = tester.getTopLeft(find.text('Srv1 · B')).dy;
    final a = tester.getTopLeft(find.text('Srv1 · A')).dy;
    expect(b < a, isTrue);
  });

  testWidgets('moving an unranked row up ranks it', (tester) async {
    final priority = await _pump(tester, [_lib('1', 'a', 'A'), _lib('1', 'b', 'B')], stored: ['1:a']);

    await _key(tester, LogicalKeyboardKey.arrowDown); // cursor to unranked B
    await _key(tester, LogicalKeyboardKey.select);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(priority.priority, ['1:b', '1:a']);
    expect(find.text('Unranked (by resolution)'), findsNothing);
  });

  testWidgets('stored keys for missing libraries are not shown and are dropped on next save', (tester) async {
    final priority = await _pump(tester, [_lib('1', 'a', 'A'), _lib('1', 'b', 'B')], stored: ['9:gone', '1:a', '1:b']);

    expect(find.textContaining('gone'), findsNothing);
    // Nothing is written on open.
    expect(priority.priority, ['9:gone', '1:a', '1:b']);

    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.select);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(priority.priority, ['1:b', '1:a']);
  });
}
