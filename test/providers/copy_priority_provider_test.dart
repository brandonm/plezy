import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/copy_priority.dart';
import 'package:plezy/providers/copy_priority_provider.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/storage_service.dart';

import '../test_helpers/prefs.dart';

const _movies = CopyPrioritySection.movies;
const _shows = CopyPrioritySection.shows;

void main() {
  setUp(resetSharedPreferencesForTest);

  group('CopyPriorityProvider', () {
    test('loads the stored lists for its profile', () async {
      final storage = await StorageService.getInstance();
      await storage.saveCopyPriorityForProfile('p1', _movies, ['s1:10', 's2:20']);
      await storage.saveCopyPriorityForProfile('p1', _shows, ['s2:21']);

      final p = CopyPriorityProvider(storageService: storage, profileId: 'p1');
      await p.ensureInitialized();
      expect(p.priority.movies, ['s1:10', 's2:20']);
      expect(p.priority.shows, ['s2:21']);

      final other = CopyPriorityProvider(storageService: storage, profileId: 'p2');
      await other.ensureInitialized();
      expect(other.priority.movies, isEmpty);
      expect(other.priority.shows, isEmpty);

      p.dispose();
      other.dispose();
    });

    test('setPriority persists one section, keeps the other, and notifies', () async {
      final storage = await StorageService.getInstance();
      await storage.saveCopyPriorityForProfile('p1', _shows, ['s3:30']);
      final p = CopyPriorityProvider(storageService: storage, profileId: 'p1');
      await p.ensureInitialized();

      var notified = 0;
      p.addListener(() => notified++);

      await p.setPriority(_movies, ['s2:20', 's1:10']);

      expect(notified, 1);
      expect(p.priority.movies, ['s2:20', 's1:10']);
      expect(p.priority.shows, ['s3:30']);
      expect(storage.getCopyPriorityForProfile('p1', _movies), ['s2:20', 's1:10']);
      expect(storage.getCopyPriorityForProfile('p1', _shows), ['s3:30']);

      p.dispose();
    });

    test('saving both sections at once keeps both', () async {
      final storage = await StorageService.getInstance();
      final p = CopyPriorityProvider(storageService: storage, profileId: 'p1');
      await p.ensureInitialized();

      await Future.wait([
        p.setPriority(_movies, ['s1:10']),
        p.setPriority(_shows, ['s2:20']),
      ]);

      expect(p.priority.movies, ['s1:10']);
      expect(p.priority.shows, ['s2:20']);
      p.dispose();
    });

    test('persists across provider instances', () async {
      final first = CopyPriorityProvider(profileId: 'p1');
      await first.ensureInitialized();
      await first.setPriority(_shows, ['s1:10']);
      first.dispose();

      BaseSharedPreferencesService.resetForTesting();

      final second = CopyPriorityProvider(profileId: 'p1');
      await second.ensureInitialized();
      expect(second.priority.shows, ['s1:10']);
      expect(second.priority.movies, isEmpty);
      second.dispose();
    });
  });
}
