import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../media/copy_selection.dart' show CopyPickRef;
import '../media/media_kind.dart';
import '../utils/external_ids.dart';
import 'storage_service.dart';

/// Record cap; the oldest records (by [CopyPick.at]) are evicted past it.
const maxCopyPicks = 500;

/// A remembered manual copy pick: [key] names the chosen copy (movie) or show
/// copy (series), [lib] is `serverId:libraryId`, [sig] the version signature,
/// [at] the write time in ms since epoch.
class CopyPick {
  final String key;
  final String lib;
  final String? sig;
  final int at;

  const CopyPick({required this.key, required this.lib, this.sig, required this.at});

  CopyPickRef get ref => (key: key, lib: lib, sig: sig);

  Map<String, dynamic> toJson() => {'key': key, 'lib': lib, if (sig != null) 'sig': sig, 'at': at};

  factory CopyPick.fromJson(Map<String, dynamic> j) =>
      CopyPick(key: j['key'] as String, lib: j['lib'] as String, sig: j['sig'] as String?, at: j['at'] as int);
}

/// Catalogue aliases (`movie|tmdb:603`, `show|tvdb:81189`) a title is filed
/// under. Only tmdb, tvdb and imdb count; missing ids are skipped.
Set<String> copyAliases(MediaKind kind, Iterable<ExternalIds> ids) {
  final prefix = kind.id;
  return {
    for (final id in ids) ...[
      if (id.tmdb != null) '$prefix|tmdb:${id.tmdb}',
      if (id.tvdb != null) '$prefix|tvdb:${id.tvdb}',
      if (id.imdb != null) '$prefix|imdb:${id.imdb}',
    ],
  };
}

/// Per-profile remembered picks, filed under every alias of a title so a pick
/// made where only TVDB was known is found from a server that only has TMDB.
class CopyPickStore {
  final StorageService _storage;
  final String _profileId;

  CopyPickStore(this._storage, this._profileId);

  final ValueNotifier<int> _revision = ValueNotifier(0);

  /// Ticks after every [write] and every [clear] that removed something, so
  /// a page naming the copy Play starts can choose again.
  ValueListenable<int> get changes => _revision;

  /// Newest record any of [aliases] points at.
  CopyPick? read(Set<String> aliases) {
    final data = _load();
    CopyPick? best;
    for (final alias in aliases) {
      final id = data.aliases[alias];
      final pick = id == null ? null : data.records[id];
      if (pick != null && (best == null || pick.at > best.at)) best = pick;
    }
    return best;
  }

  /// Files [pick] under all [aliases], re-pointing any alias that already
  /// belonged to another record. Records left with no alias are dropped.
  Future<void> write(Set<String> aliases, CopyPick pick) async {
    if (aliases.isEmpty) return;
    final data = _load();
    data.records[pick.key] = pick;
    for (final alias in aliases) {
      data.aliases[alias] = pick.key;
    }
    final live = data.aliases.values.toSet();
    data.records.removeWhere((id, _) => !live.contains(id));
    if (data.records.length > maxCopyPicks) {
      final byAge = data.records.entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
      final evict = byAge.take(data.records.length - maxCopyPicks).map((e) => e.key).toSet();
      data.records.removeWhere((id, _) => evict.contains(id));
      data.aliases.removeWhere((_, id) => evict.contains(id));
    }
    await _save(data);
    _revision.value++;
  }

  /// Removes the record(s) [aliases] point at, and every alias of them.
  Future<void> clear(Set<String> aliases) async {
    final data = _load();
    final doomed = {for (final a in aliases) ?data.aliases[a]};
    if (doomed.isEmpty) return;
    data.records.removeWhere((id, _) => doomed.contains(id));
    data.aliases.removeWhere((_, id) => doomed.contains(id));
    await _save(data);
    _revision.value++;
  }

  _Data _load() {
    final raw = _storage.getCopyPicksJsonForProfile(_profileId);
    if (raw == null) return _Data();
    try {
      final j = json.decode(raw) as Map<String, dynamic>;
      final records = (j['records'] as Map).map(
        (k, v) => MapEntry(k as String, CopyPick.fromJson(Map<String, dynamic>.from(v as Map))),
      );
      final aliases = {
        for (final e in (j['aliases'] as Map).entries)
          if (records.containsKey(e.value)) e.key as String: e.value as String,
      };
      return _Data(records, aliases);
    } catch (_) {
      return _Data();
    }
  }

  Future<void> _save(_Data data) => _storage.saveCopyPicksJsonForProfile(
    _profileId,
    json.encode({'records': data.records.map((k, v) => MapEntry(k, v.toJson())), 'aliases': data.aliases}),
  );
}

class _Data {
  final Map<String, CopyPick> records;
  final Map<String, String> aliases;

  _Data([Map<String, CopyPick>? records, Map<String, String>? aliases])
    : records = records ?? {},
      aliases = aliases ?? {};
}
