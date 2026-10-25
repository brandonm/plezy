import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/copy_priority.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/storage_service.dart';

import '../test_helpers/prefs.dart';

const _movies = CopyPrioritySection.movies;
const _shows = CopyPrioritySection.shows;

void main() {
  setUp(resetSharedPreferencesForTest);

  group('StorageService copy priority', () {
    test('copy priority round-trips per profile and per section', () async {
      final storage = await StorageService.getInstance();

      await storage.saveCopyPriorityForProfile('p1', _movies, ['s1:10', 's2:20']);
      await storage.saveCopyPriorityForProfile('p1', _shows, ['s2:21']);

      expect(storage.getCopyPriorityForProfile('p1', _movies), ['s1:10', 's2:20']);
      expect(storage.getCopyPriorityForProfile('p1', _shows), ['s2:21']);
      expect(storage.getCopyPriorityForProfile('p2', _movies), isEmpty);
      expect(storage.getCopyPriorityForProfile('p2', _shows), isEmpty);
    });

    test('server removal drops that server from both lists (profile path)', () async {
      final storage = await StorageService.getInstance();
      await storage.saveCopyPriorityForProfile('p1', _movies, ['s1:10', 's2:20', 's1:11']);
      await storage.saveCopyPriorityForProfile('p1', _shows, ['s1:30', 's2:40']);
      await storage.saveCopyPriorityForProfile('p2', _movies, ['s1:10', 's2:20']);

      await storage.clearLibraryPreferencesForServer(ServerId('s1'), profileId: 'p1');

      expect(storage.getCopyPriorityForProfile('p1', _movies), ['s2:20']);
      expect(storage.getCopyPriorityForProfile('p1', _shows), ['s2:40']);
      expect(storage.getCopyPriorityForProfile('p2', _movies), ['s1:10', 's2:20']);
    });

    test('server removal drops that server from both lists (everywhere path)', () async {
      final storage = await StorageService.getInstance();
      await storage.saveCopyPriorityForProfile('p1', _movies, ['s1:10', 's2:20', 's1:11']);
      await storage.saveCopyPriorityForProfile('p2', _shows, ['s2:21', 's1:12']);

      await storage.clearLibraryPreferencesForServerEverywhere(ServerId('s1'));

      expect(storage.getCopyPriorityForProfile('p1', _movies), ['s2:20']);
      expect(storage.getCopyPriorityForProfile('p2', _shows), ['s2:21']);
    });

    test('clearLibraryPreferences clears both lists', () async {
      final storage = await StorageService.getInstance();
      await storage.setActiveProfileId('p1');
      await storage.saveCopyPriorityForProfile('p1', _movies, ['s1:10']);
      await storage.saveCopyPriorityForProfile('p1', _shows, ['s1:20']);
      expect(storage.getCopyPriorityForProfile('p1', _movies), ['s1:10']);

      await storage.clearLibraryPreferences();

      expect(storage.getCopyPriorityForProfile('p1', _movies), isEmpty);
      expect(storage.getCopyPriorityForProfile('p1', _shows), isEmpty);
    });
  });
}
