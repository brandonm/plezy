import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../media/media_version.dart';
import '../services/copy_resolver.dart';
import '../utils/dialogs.dart';

/// A row of the grouped Play Version picker: [copy] at [versionIndex], or
/// [reset] for "Use priority order".
typedef CopyVersionChoice = ({MediaItem copy, int versionIndex, bool reset});

/// [copy]'s server and library as one name, "Silo Movies 4K Remux", or its
/// server alone when the copy has no library title; null when it has neither.
String? copyLibraryName(MediaItem copy) {
  final (server, library) = (copy.serverName, copy.libraryTitle);
  if (server != null && library != null) return t.mediaMenu.copyName(server: server, library: library);
  return server ?? library;
}

/// [copy]'s server and library as a picker row names them, "Silo · Movies 4K".
String _copySource(MediaItem copy) {
  final (server, library) = (copy.serverName, copy.libraryTitle);
  if (server != null && library != null) return t.mediaMenu.copySource(server: server, library: library);
  return server ?? library ?? '';
}

/// How many versions [copies] offer in all. A copy whose version list the
/// server didn't send still plays one.
int copyVersionCount(ResolvedCopies copies) => copies.copies.fold(0, (count, copy) {
  final versions = copy.mediaVersions?.length ?? 0;
  return count + (versions > 0 ? versions : 1);
});

/// Whether [copies] holds nothing but [opened] itself: the lookup found no
/// other copy, so the single-server flows apply unchanged.
bool isOpenedAlone(ResolvedCopies copies, MediaItem opened) =>
    copies.copies.length == 1 && copies.copies.single.globalKey == opened.globalKey;

/// The Play Version picker across servers: every version of every copy in
/// [copies]'s best-first order, each copy's versions together, each row
/// "Server · Library · `displayLabel`". With [hasPick], "Use priority order" comes
/// first. Null when dismissed.
Future<CopyVersionChoice?> showCopyVersionPicker(BuildContext context, ResolvedCopies copies, {required bool hasPick}) {
  return showOptionPickerDialog<CopyVersionChoice>(
    context,
    title: t.mediaMenu.playVersion,
    options: [
      if (hasPick)
        (
          icon: Symbols.format_list_numbered_rounded,
          label: t.mediaMenu.usePriorityOrder,
          value: (copy: copies.copies.first, versionIndex: 0, reset: true),
        ),
      for (final copy in copies.copies) ..._copyRows(copy),
    ],
  );
}

List<({IconData? icon, String label, CopyVersionChoice value})> _copyRows(MediaItem copy) {
  final versions = copy.mediaVersions ?? const <MediaVersion>[];
  final source = _copySource(copy);
  String label(MediaVersion? version) {
    if (version == null) return source;
    if (source.isEmpty) return version.displayLabel;
    return t.mediaMenu.copyVersion(source: source, version: version.displayLabel);
  }

  if (versions.isEmpty) {
    return [(icon: Symbols.video_file_rounded, label: label(null), value: (copy: copy, versionIndex: 0, reset: false))];
  }
  return [
    for (var i = 0; i < versions.length; i++)
      (icon: Symbols.video_file_rounded, label: label(versions[i]), value: (copy: copy, versionIndex: i, reset: false)),
  ];
}
