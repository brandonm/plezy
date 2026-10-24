import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_item_merge.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_version.dart';
import '../test_helpers/media_items.dart';

void main() {
  MediaItem item({String? serverId, String? serverName, String? libraryId, String? libraryTitle}) => testMediaItem(
    id: 'item',
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    serverId: serverId,
    serverName: serverName,
    libraryId: libraryId,
    libraryTitle: libraryTitle,
  );

  test('uses the authoritative fallback when both items omit server identity', () {
    final merged = mergeFetchedMediaItem(fetched: item(), fallbackServerId: ServerId('fallback'));

    expect(merged.serverId, 'fallback');
    expect(merged.globalKey, 'fallback:item');
  });

  test('preserves existing identity while preferring fetched library context', () {
    final merged = mergeFetchedMediaItem(
      fetched: item(serverId: 'fetched', serverName: 'Fetched', libraryId: 'new-lib', libraryTitle: 'New'),
      existing: item(serverId: 'existing', serverName: 'Existing', libraryId: 'old-lib', libraryTitle: 'Old'),
      fallbackServerId: ServerId('fallback'),
    );

    expect(merged.serverId, 'existing');
    expect(merged.serverName, 'Existing');
    expect(merged.libraryId, 'new-lib');
    expect(merged.libraryTitle, 'New');
  });

  test('fills missing fetched library context from the existing item', () {
    final merged = mergeFetchedMediaItem(
      fetched: item(),
      existing: item(libraryId: 'old-lib', libraryTitle: 'Old'),
      fallbackServerId: ServerId('fallback'),
    );

    expect(merged.libraryId, 'old-lib');
    expect(merged.libraryTitle, 'Old');
  });

  test('a fetched item that moved libraries does not inherit the old label', () {
    final merged = mergeFetchedMediaItem(
      fetched: item(libraryId: 'new-lib'),
      existing: item(libraryId: 'old-lib', libraryTitle: 'Old'),
      fallbackServerId: ServerId('fallback'),
    );

    expect(merged.libraryId, 'new-lib');
    expect(merged.libraryTitle, isNull);
  });

  test('a fetched item naming the same library fills its label from the existing item', () {
    final merged = mergeFetchedMediaItem(
      fetched: item(libraryId: 'old-lib'),
      existing: item(libraryId: 'old-lib', libraryTitle: 'Old'),
      fallbackServerId: ServerId('fallback'),
    );

    expect(merged.libraryId, 'old-lib');
    expect(merged.libraryTitle, 'Old');
  });

  MediaItem copy({
    required String id,
    String? libraryId,
    String? libraryTitle,
    String? videoResolution,
    List<MediaVersion>? mediaVersions,
  }) => testMediaItem(
    id: id,
    serverId: 'server-1',
    serverName: 'Living Room',
    libraryId: libraryId ?? (libraryTitle == null ? null : '$id-lib'),
    libraryTitle: libraryTitle,
    mediaVersions:
        mediaVersions ??
        (videoResolution == null ? null : [MediaVersion(id: '$id-v', videoResolution: videoResolution)]),
  );

  test('orders library copies by resolution, best first', () {
    final merged = mergeLibraryCopies(const [], [
      copy(id: 'hd', libraryTitle: 'Movies', videoResolution: '1080'),
      copy(id: 'uhd', libraryTitle: '4K Movies', videoResolution: '4k'),
    ]);

    expect(merged.map((item) => item.id), ['uhd', 'hd']);
  });

  test('keeps copies a later pass did not return', () {
    final merged = mergeLibraryCopies([copy(id: 'hd', libraryTitle: 'Movies')], const []);

    expect(merged.map((item) => item.id), ['hd']);
  });

  test('an unstamped re-resolve does not strip a copy of its library', () {
    // Jellyfin's library stamp is a best-effort ancestors lookup that returns
    // the item unstamped when it fails. Losing the title would make this copy
    // indistinguishable from its sibling in the server's other library.
    final merged = mergeLibraryCopies(
      [copy(id: 'hd', libraryTitle: 'Movies', videoResolution: '1080')],
      [copy(id: 'hd')],
    );

    expect(merged.single.libraryId, 'hd-lib');
    expect(merged.single.libraryTitle, 'Movies');
    expect(merged.single.serverName, 'Living Room');
    expect(merged.single.mediaVersions?.single.videoResolution, '1080');
  });

  test('a re-resolve carrying fresher library context wins', () {
    final merged = mergeLibraryCopies(
      [copy(id: 'hd', libraryTitle: 'Movies', videoResolution: '1080')],
      [copy(id: 'hd', libraryTitle: 'Renamed Movies', videoResolution: '4k')],
    );

    expect(merged.single.libraryTitle, 'Renamed Movies');
    expect(merged.single.mediaVersions?.single.videoResolution, '4k');
  });

  test('a re-resolve naming another library takes its id without the old label', () {
    final merged = mergeLibraryCopies(
      [copy(id: 'hd', libraryTitle: 'Movies')],
      [copy(id: 'hd', libraryId: 'other-lib')],
    );

    expect(merged.single.libraryId, 'other-lib');
    expect(merged.single.libraryTitle, isNull);
  });

  test('an empty version list is treated as absent, not as a downgrade', () {
    final merged = mergeLibraryCopies(
      [copy(id: 'hd', libraryTitle: 'Movies', videoResolution: '1080')],
      [copy(id: 'hd', libraryTitle: 'Movies', mediaVersions: const [])],
    );

    expect(merged.single.mediaVersions?.single.videoResolution, '1080');
  });

  group('compareCopiesByPriority', () {
    MediaItem ranked(String id, String serverId, String? libraryId, {int? height}) => testMediaItem(
      id: id,
      serverId: serverId,
      serverName: serverId,
      libraryId: libraryId,
      mediaVersions: height == null ? null : [MediaVersion(id: '$id-v', height: height)],
    );

    List<String> order(List<MediaItem> items, Comparator<MediaItem> cmp) =>
        ([...items]..sort(cmp)).map((i) => i.id).toList();

    test('ranked libraries order by list index', () {
      final cmp = compareCopiesByPriority(['silo:remux', 'silo:4k', 'plex:movies']);
      final plexMovies = ranked('a', 'plex', 'movies', height: 1080);
      final silo4k = ranked('b', 'silo', '4k', height: 2160);
      final siloRemux = ranked('c', 'silo', 'remux', height: 2160);

      expect(order([plexMovies, silo4k, siloRemux], cmp), ['c', 'b', 'a']);
    });

    test('any ranked copy beats any unranked copy', () {
      final cmp = compareCopiesByPriority(['plex:movies']);
      final rankedLow = ranked('low', 'plex', 'movies', height: 720);
      final unrankedHigh = ranked('high', 'silo', 'other', height: 2160);

      expect(order([unrankedHigh, rankedLow], cmp), ['low', 'high']);
      expect(order([rankedLow, unrankedHigh], cmp), ['low', 'high']);
    });

    test('unranked copies order by best resolution', () {
      final cmp = compareCopiesByPriority(['plex:movies']);
      final sd = ranked('sd', 'silo', 'x', height: 480);
      final uhd = ranked('uhd', 'silo', 'y', height: 2160);
      final none = ranked('none', 'silo', 'z');

      expect(order([none, sd, uhd], cmp), ['uhd', 'sd', 'none']);
    });

    test('copy without libraryId is unranked', () {
      final cmp = compareCopiesByPriority(['plex:movies']);
      final rankedCopy = ranked('r', 'plex', 'movies', height: 480);
      final unstamped = ranked('u', 'plex', null, height: 2160);

      expect(order([unstamped, rankedCopy], cmp), ['r', 'u']);
    });

    test('ties fall through to compareLibraryCopies and are total', () {
      final cmp = compareCopiesByPriority(const []);
      final items = [
        ranked('c', 'silo', 'x', height: 1080),
        ranked('a', 'silo', 'x', height: 1080),
        ranked('b', 'silo', 'x', height: 1080),
      ];

      final first = order(items, cmp);
      expect(first, ['a', 'b', 'c']);
      expect(order(items.reversed.toList(), cmp), first);
      expect(order(items, cmp), first);
      expect(cmp(items[0], items[0]), 0);
    });

    test('a priority entry naming no present library is ignored', () {
      final cmp = compareCopiesByPriority(['gone:1', 'silo:4k']);
      final silo4k = ranked('k', 'silo', '4k', height: 480);
      final other = ranked('o', 'plex', 'movies', height: 2160);

      expect(order([other, silo4k], cmp), ['k', 'o']);
    });
  });

  test('mergeLibraryCopies uses the supplied comparator', () {
    final low = copy(id: 'a-low', libraryTitle: 'A', videoResolution: '480');
    final high = copy(id: 'b-high', libraryTitle: 'B', videoResolution: '4k');

    expect(mergeLibraryCopies([low], [high]).map((i) => i.id), ['b-high', 'a-low']);
    final merged = mergeLibraryCopies([low], [high], compare: (a, b) => a.id.compareTo(b.id));
    expect(merged.map((i) => i.id), ['a-low', 'b-high']);
  });
}
