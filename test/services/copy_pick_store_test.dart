import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/copy_pick_store.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/external_ids.dart';

import '../test_helpers/prefs.dart';

CopyPick _pick(String key, String lib, int at, {String? sig}) => CopyPick(key: key, lib: lib, sig: sig, at: at);

void main() {
  late StorageService storage;
  late CopyPickStore store;

  setUp(() async {
    resetSharedPreferencesForTest();
    storage = await StorageService.getInstance();
    store = CopyPickStore(storage, 'p1');
  });

  test('written under all aliases and read from any one', () async {
    await store.write({'show|tmdb:1', 'show|tvdb:2'}, _pick('s1:10', 's1:3', 5, sig: 'sig'));
    final got = store.read({'show|tvdb:2'});
    expect(got?.lib, 's1:3');
    expect(got?.ref, (key: 's1:10', lib: 's1:3', sig: 'sig'));
    expect(store.read({'show|imdb:x'}), isNull);
  });

  test('persists across store instances and is per profile', () async {
    await store.write({'movie|tmdb:1'}, _pick('s1:10', 's1:3', 5));
    expect(CopyPickStore(storage, 'p1').read({'movie|tmdb:1'}), isNotNull);
    expect(CopyPickStore(storage, 'p2').read({'movie|tmdb:1'}), isNull);
  });

  test('newest record wins when aliases point at different records', () async {
    await store.write({'show|tmdb:1'}, _pick('a', 's1:1', 10));
    await store.write({'show|tvdb:2'}, _pick('b', 's2:1', 20));
    expect(store.read({'show|tmdb:1', 'show|tvdb:2'})?.key, 'b');
    await store.write({'show|tmdb:9'}, _pick('c', 's3:1', 5));
    expect(store.read({'show|tmdb:1', 'show|tmdb:9'})?.key, 'a');
  });

  test('overlapping write re-points aliases and drops orphaned records', () async {
    await store.write({'show|tmdb:1', 'show|tvdb:2'}, _pick('old', 's1:1', 10));
    await store.write({'show|tvdb:2', 'show|tmdb:1', 'show|imdb:t'}, _pick('new', 's2:1', 20));
    expect(store.read({'show|tmdb:1'})?.key, 'new');
    expect(store.read({'show|imdb:t'})?.key, 'new');
    expect(storage.getCopyPicksJsonForProfile('p1')!.contains('"old"'), isFalse);
  });

  test('partial overlap keeps the old record for its remaining alias', () async {
    await store.write({'show|tmdb:1', 'show|tvdb:2'}, _pick('old', 's1:1', 10));
    await store.write({'show|tvdb:2'}, _pick('new', 's2:1', 20));
    expect(store.read({'show|tmdb:1'})?.key, 'old');
    expect(store.read({'show|tvdb:2'})?.key, 'new');
  });

  test('copyAliases skips missing ids and prefixes kind', () {
    expect(copyAliases(MediaKind.show, const [ExternalIds(tvdb: 81189, tmdb: 1399)]), {
      'show|tvdb:81189',
      'show|tmdb:1399',
    });
    expect(copyAliases(MediaKind.movie, const [ExternalIds(imdb: 'tt1', anidb: 5), ExternalIds(tmdb: 2)]), {
      'movie|imdb:tt1',
      'movie|tmdb:2',
    });
    expect(copyAliases(MediaKind.movie, const [ExternalIds()]), isEmpty);
  });

  test('cap 500 evicts oldest', () async {
    for (var i = 0; i < 501; i++) {
      await store.write({'movie|tmdb:$i'}, _pick('k$i', 's1:1', 1000 + i));
    }
    expect(store.read({'movie|tmdb:0'}), isNull);
    expect(store.read({'movie|tmdb:1'})?.key, 'k1');
    expect(store.read({'movie|tmdb:500'})?.key, 'k500');
  });

  test('clear removes the record and all its aliases', () async {
    await store.write({'show|tmdb:1', 'show|tvdb:2'}, _pick('a', 's1:1', 10));
    await store.write({'show|tmdb:7'}, _pick('b', 's1:1', 10));
    await store.clear({'show|tvdb:2'});
    expect(store.read({'show|tmdb:1'}), isNull);
    expect(store.read({'show|tvdb:2'}), isNull);
    expect(store.read({'show|tmdb:7'})?.key, 'b');
  });

  group('server removal', () {
    Future<void> seed(String profile) =>
        CopyPickStore(storage, profile).write({'movie|tmdb:1', 'movie|imdb:t'}, _pick('s1:10', 's1:3', 10));

    test('profile path deletes records whose lib names it, with aliases', () async {
      await seed('p1');
      await store.write({'movie|tmdb:2'}, _pick('s2:20', 's2:4', 11));
      await seed('p2');

      await storage.clearLibraryPreferencesForServer(ServerId('s1'), profileId: 'p1');

      expect(store.read({'movie|tmdb:1'}), isNull);
      expect(store.read({'movie|imdb:t'}), isNull);
      expect(store.read({'movie|tmdb:2'})?.key, 's2:20');
      expect(CopyPickStore(storage, 'p2').read({'movie|tmdb:1'}), isNotNull);
    });

    test('everywhere path deletes across every profile', () async {
      await seed('p1');
      await seed('p2');
      await CopyPickStore(storage, 'p2').write({'movie|tmdb:2'}, _pick('s2:20', 's2:4', 11));

      await storage.clearLibraryPreferencesForServerEverywhere(ServerId('s1'));

      final p2 = CopyPickStore(storage, 'p2');
      expect(store.read({'movie|tmdb:1'}), isNull);
      expect(p2.read({'movie|tmdb:1'}), isNull);
      expect(p2.read({'movie|imdb:t'}), isNull);
      expect(p2.read({'movie|tmdb:2'})?.key, 's2:20');
    });

    test('server id prefix does not match a longer id', () async {
      await store.write({'movie|tmdb:1'}, _pick('s10:1', 's10:3', 10));
      await storage.clearLibraryPreferencesForServerEverywhere(ServerId('s1'));
      expect(store.read({'movie|tmdb:1'}), isNotNull);
    });
  });
}
