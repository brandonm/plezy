import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/copy_selection.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/utils/external_ids.dart';

import '../test_helpers/media_items.dart';

MediaItem _episode({
  String id = 'e1',
  int? season = 1,
  int? number = 3,
  int? durationMs,
  String serverId = 's1',
  String? grandparentId = 'show1',
  String? libraryId,
  String? libraryTitle,
}) => testMediaItem(
  id: id,
  kind: MediaKind.episode,
  parentIndex: season,
  index: number,
  durationMs: durationMs,
  serverId: serverId,
  grandparentId: grandparentId,
  libraryId: libraryId,
  libraryTitle: libraryTitle,
);

MediaItem _movie(
  String id, {
  String serverId = 's1',
  String? libraryId,
  int? durationMs,
  int? viewOffsetMs,
  int? viewCount,
}) => testMediaItem(
  id: id,
  serverId: serverId,
  libraryId: libraryId,
  durationMs: durationMs,
  viewOffsetMs: viewOffsetMs,
  viewCount: viewCount,
);

void main() {
  group('acceptEpisodeCopy', () {
    bool accept(
      MediaItem opened,
      MediaItem cand, {
      ExternalIds openedIds = const ExternalIds(),
      ExternalIds candIds = const ExternalIds(),
    }) => acceptEpisodeCopy(opened: opened, openedIds: openedIds, candidate: cand, candidateIds: candIds);

    test('agreeing episode ids accept', () {
      expect(
        accept(
          _episode(),
          _episode(id: 'e2', serverId: 's2'),
          openedIds: const ExternalIds(tvdb: 99, imdb: 'tt1'),
          candIds: const ExternalIds(tvdb: 99),
        ),
        isTrue,
      );
    });

    test('one contradicting id rejects even with agreeing others', () {
      expect(
        accept(
          _episode(),
          _episode(id: 'e2', serverId: 's2'),
          openedIds: const ExternalIds(tvdb: 99, imdb: 'tt1'),
          candIds: const ExternalIds(tvdb: 99, imdb: 'tt2'),
        ),
        isFalse,
      );
    });

    test('no ids on either side: durations within 10% accept, outside reject', () {
      expect(accept(_episode(durationMs: 1_000_000), _episode(id: 'e2', durationMs: 1_099_000)), isTrue);
      expect(accept(_episode(durationMs: 1_000_000), _episode(id: 'e2', durationMs: 1_101_000)), isFalse);
    });

    test('no ids and an unknown duration rejects', () {
      expect(accept(_episode(durationMs: 1_000_000), _episode(id: 'e2')), isFalse);
      expect(accept(_episode(), _episode(id: 'e2', durationMs: 1_000_000)), isFalse);
    });

    test('both sides have ids but no shared provider rejects even with matching duration', () {
      expect(
        accept(
          _episode(durationMs: 1_000_000),
          _episode(id: 'e2', durationMs: 1_000_000),
          openedIds: const ExternalIds(tvdb: 99),
          candIds: const ExternalIds(imdb: 'tt1'),
        ),
        isFalse,
      );
    });

    test('ids on one side only falls back to duration', () {
      expect(
        accept(
          _episode(durationMs: 1_000_000),
          _episode(id: 'e2', durationMs: 1_050_000),
          openedIds: const ExternalIds(tvdb: 99),
        ),
        isTrue,
      );
    });

    test('zero duration counts as unknown', () {
      expect(accept(_episode(durationMs: 0), _episode(id: 'e2', durationMs: 0)), isFalse);
    });

    test('exactly 10% accepts', () {
      expect(accept(_episode(durationMs: 1_000_000), _episode(id: 'e2', durationMs: 1_100_000)), isTrue);
    });

    test('season 0 never matches season 1 of the same number', () {
      expect(
        accept(
          _episode(season: 0),
          _episode(id: 'e2', season: 1),
          openedIds: const ExternalIds(tvdb: 99),
          candIds: const ExternalIds(tvdb: 99),
        ),
        isFalse,
      );
    });

    test('a different episode number never matches', () {
      expect(
        accept(
          _episode(number: 3),
          _episode(id: 'e2', number: 4),
          openedIds: const ExternalIds(tvdb: 99),
          candIds: const ExternalIds(tvdb: 99),
        ),
        isFalse,
      );
    });
  });

  group('stampFromShow', () {
    final show = testMediaItem(id: 'show1', kind: MediaKind.show, libraryId: 'L1', libraryTitle: 'Shows');

    test('episode inherits the show copy library stamp', () {
      final stamped = stampFromShow(_episode(), show);
      expect(stamped.libraryId, 'L1');
      expect(stamped.libraryTitle, 'Shows');
    });

    test('an existing episode stamp is kept', () {
      final stamped = stampFromShow(_episode(libraryId: 'L9', libraryTitle: 'Own'), show);
      expect(stamped.libraryId, 'L9');
      expect(stamped.libraryTitle, 'Own');
    });
  });

  group('furthestResumeOffsetMs', () {
    final target = _movie('t', durationMs: 1_000_000);

    test('furthest in-progress copy wins', () {
      final copies = [
        _movie('a', durationMs: 1_000_000, viewOffsetMs: 200_000),
        _movie('b', durationMs: 1_020_000, viewOffsetMs: 700_000),
        _movie('c', durationMs: 1_000_000, viewOffsetMs: 400_000),
      ];
      expect(furthestResumeOffsetMs(target, copies), 700_000);
    });

    test('watched copy with a residual offset is ignored while an unwatched copy has progress', () {
      final copies = [
        _movie('a', durationMs: 1_000_000, viewOffsetMs: 200_000),
        _movie('b', durationMs: 1_000_000, viewOffsetMs: 600_000, viewCount: 1),
      ];
      expect(furthestResumeOffsetMs(target, copies), 200_000);
    });

    test('a rewatch in progress lends its offset when no unwatched copy has progress', () {
      final copies = [
        _movie('t', durationMs: 1_000_000),
        _movie('a', durationMs: 1_000_000, viewOffsetMs: 300_000, viewCount: 1),
        _movie('b', durationMs: 1_000_000, viewOffsetMs: 400_000, viewCount: 2),
        // Watched too, but its length is more than 5% off.
        _movie('c', durationMs: 1_100_000, viewOffsetMs: 900_000, viewCount: 1),
      ];
      expect(furthestResumeOffsetMs(target, copies), 400_000);
    });

    test('copy whose duration differs by more than 5% is ignored', () {
      final copies = [
        _movie('a', durationMs: 1_050_000, viewOffsetMs: 100_000),
        _movie('b', durationMs: 1_051_000, viewOffsetMs: 900_000),
        _movie('c', durationMs: 900_000, viewOffsetMs: 800_000),
      ];
      expect(furthestResumeOffsetMs(target, copies), 100_000);
    });

    test('copy exactly 5% off is kept', () {
      expect(furthestResumeOffsetMs(target, [_movie('a', durationMs: 1_050_000, viewOffsetMs: 100_000)]), 100_000);
    });

    test('copy with an unknown duration is ignored', () {
      expect(furthestResumeOffsetMs(target, [_movie('a', viewOffsetMs: 500_000)]), isNull);
    });

    test('no in-progress copy returns null', () {
      expect(furthestResumeOffsetMs(target, [_movie('a', durationMs: 1_000_000)]), isNull);
      expect(furthestResumeOffsetMs(target, const []), isNull);
    });
  });

  group('chooseTarget', () {
    final a = _movie('a', serverId: 's1', libraryId: 'L1');
    final b = _movie('b', serverId: 's2', libraryId: 'L2');

    test('pick by key beats ranking', () {
      expect(chooseTarget([a, b], (key: 's2:b', lib: 's1:L1', sig: null)), same(b));
    });

    test('pick by lib is used when key is absent', () {
      expect(chooseTarget([a, b], (key: 's2:gone', lib: 's2:L2', sig: null)), same(b));
    });

    test('pick naming no present copy falls back to first', () {
      expect(chooseTarget([a, b], (key: 's3:x', lib: 's3:L3', sig: null)), same(a));
    });

    test('no pick returns first', () {
      expect(chooseTarget([a, b], null), same(a));
    });

    test('pick key naming the show copy selects that server\'s episode', () {
      final e1 = _episode(id: 'e1', serverId: 's1', grandparentId: 'show1');
      final e2 = _episode(id: 'e2', serverId: 's2', grandparentId: 'show2');
      expect(copyPickKey(e2), 's2:show2');
      expect(chooseTarget([e1, e2], (key: 's2:show2', lib: 'x:y', sig: null)), same(e2));
    });

    test('movie pick key matches the copy globalKey', () {
      expect(copyPickKey(a), a.globalKey);
      expect(chooseTarget([b, a], (key: 's1:a', lib: 'x:y', sig: null)), same(a));
    });
  });
}
