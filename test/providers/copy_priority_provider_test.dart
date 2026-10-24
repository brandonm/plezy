import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/providers/copy_priority_provider.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/storage_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  group('CopyPriorityProvider', () {
    test('loads the stored list for its profile', () async {
      final storage = await StorageService.getInstance();
      await storage.saveCopyPriorityForProfile('p1', ['s1:10', 's2:20']);

      final p = CopyPriorityProvider(storageService: storage, profileId: 'p1');
      await p.ensureInitialized();
      expect(p.priority, ['s1:10', 's2:20']);

      final other = CopyPriorityProvider(storageService: storage, profileId: 'p2');
      await other.ensureInitialized();
      expect(other.priority, isEmpty);

      p.dispose();
      other.dispose();
    });

    test('setPriority persists and notifies', () async {
      final storage = await StorageService.getInstance();
      final p = CopyPriorityProvider(storageService: storage, profileId: 'p1');
      await p.ensureInitialized();

      var notified = 0;
      p.addListener(() => notified++);

      await p.setPriority(['s2:20', 's1:10']);

      expect(notified, 1);
      expect(p.priority, ['s2:20', 's1:10']);
      expect(storage.getCopyPriorityForProfile('p1'), ['s2:20', 's1:10']);

      p.dispose();
    });

    test('persists across provider instances', () async {
      final first = CopyPriorityProvider(profileId: 'p1');
      await first.ensureInitialized();
      await first.setPriority(['s1:10']);
      first.dispose();

      BaseSharedPreferencesService.resetForTesting();

      final second = CopyPriorityProvider(profileId: 'p1');
      await second.ensureInitialized();
      expect(second.priority, ['s1:10']);
      second.dispose();
    });
  });
}
