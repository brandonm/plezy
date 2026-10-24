import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/storage_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  group('StorageService copy priority', () {
    test('copy priority round-trips per profile', () async {
      final storage = await StorageService.getInstance();

      await storage.saveCopyPriorityForProfile('p1', ['s1:10', 's2:20']);

      expect(storage.getCopyPriorityForProfile('p1'), ['s1:10', 's2:20']);
      expect(storage.getCopyPriorityForProfile('p2'), isEmpty);
    });

    test('server removal drops that server from copy priority (profile path)', () async {
      final storage = await StorageService.getInstance();
      await storage.saveCopyPriorityForProfile('p1', ['s1:10', 's2:20', 's1:11']);
      await storage.saveCopyPriorityForProfile('p2', ['s1:10', 's2:20']);

      await storage.clearLibraryPreferencesForServer(ServerId('s1'), profileId: 'p1');

      expect(storage.getCopyPriorityForProfile('p1'), ['s2:20']);
      expect(storage.getCopyPriorityForProfile('p2'), ['s1:10', 's2:20']);
    });

    test('server removal drops that server from copy priority (everywhere path)', () async {
      final storage = await StorageService.getInstance();
      await storage.saveCopyPriorityForProfile('p1', ['s1:10', 's2:20', 's1:11']);
      await storage.saveCopyPriorityForProfile('p2', ['s2:21', 's1:12']);

      await storage.clearLibraryPreferencesForServerEverywhere(ServerId('s1'));

      expect(storage.getCopyPriorityForProfile('p1'), ['s2:20']);
      expect(storage.getCopyPriorityForProfile('p2'), ['s2:21']);
    });

    test('clearLibraryPreferences clears copy priority', () async {
      final storage = await StorageService.getInstance();
      await storage.setActiveProfileId('p1');
      await storage.saveCopyPriorityForProfile('p1', ['s1:10']);
      expect(storage.getCopyPriorityForProfile('p1'), ['s1:10']);

      await storage.clearLibraryPreferences();

      expect(storage.getCopyPriorityForProfile('p1'), isEmpty);
    });
  });
}
