import 'package:flutter/foundation.dart';

import 'media_kind.dart';
import 'media_library.dart';

/// Which of the copy priority's lists ranks a title's copies.
enum CopyPrioritySection {
  movies,

  /// Shows, their seasons and their episodes.
  shows;

  static CopyPrioritySection of(MediaKind kind) => kind == MediaKind.movie ? movies : shows;

  /// Whether [library] holds titles this list ranks: movies or shows, or a
  /// mixed library whose root browse includes them. A mixed library holding
  /// both is ranked in both lists.
  bool holds(MediaLibrary library) {
    final wanted = this == movies ? MediaKind.movie : MediaKind.show;
    return switch (library.kind) {
      MediaKind.movie || MediaKind.show => library.kind == wanted,
      MediaKind.unknown => library.defaultBrowseKinds.contains(wanted),
      _ => false,
    };
  }
}

/// The profile's ranking of libraries (`serverId:libraryId` keys, best first),
/// one list per [CopyPrioritySection]. Copies of one title are all of one
/// kind, so only that kind's list ever orders them.
@immutable
class CopyPriority {
  const CopyPriority({this.movies = const [], this.shows = const []});

  static const empty = CopyPriority();

  final List<String> movies;
  final List<String> shows;

  List<String> of(CopyPrioritySection section) => switch (section) {
    CopyPrioritySection.movies => movies,
    CopyPrioritySection.shows => shows,
  };

  CopyPriority withSection(CopyPrioritySection section, List<String> libraryKeys) => switch (section) {
    CopyPrioritySection.movies => CopyPriority(movies: libraryKeys, shows: shows),
    CopyPrioritySection.shows => CopyPriority(movies: movies, shows: libraryKeys),
  };
}
