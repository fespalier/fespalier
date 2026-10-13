/// Where a downloaded file lives, as a base folder the platform chooses (since 0.15.0).
///
/// A path is never absolute: an iOS app's container path changes between launches, so a stored
/// absolute path goes stale. A file is a [DownloadBase] and a relative path.
enum DownloadBase {
  /// The application support folder: private to the app, not shown to the person. The default.
  support,

  /// The cache folder: the platform may delete it when it needs space.
  cache,

  /// The documents folder: shown to the person where the platform has such a place.
  documents,
}

/// A file as a [base] and a relative [path] inside it (since 0.15.0).
final class DownloadLocation {
  /// A location. Check [isValid] before using one that came from outside the app.
  const DownloadLocation(this.base, this.path);

  /// The folder the platform resolves.
  final DownloadBase base;

  /// The path under [base], with `/` between segments.
  final String path;

  /// Whether [path] is a safe relative path: not empty, no empty segment (so no leading `/`,
  /// no `//`, no trailing `/`), no `..` segment, no `\` and no NUL character.
  bool get isValid {
    if (path.isEmpty) return false;
    if (path.contains(r'\') || path.contains('\u0000')) return false;
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '..') return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is DownloadLocation && other.base == base && other.path == path;

  @override
  int get hashCode => Object.hash(base, path);

  /// Prints the base only: a path can carry a person's file name.
  @override
  String toString() => 'DownloadLocation(${base.name})';
}
