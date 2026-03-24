import 'package:path/path.dart' as p;

/// Pure path-math utilities extracted from [LocalFileIsolateWorker] so that
/// the relative-path logic can be unit-tested without real file-system access
/// or isolates.
///
/// Contract:
///   * [collectionRoot] — absolute path of the collection root (never changes
///     across scans of sub-directories; this was the source of the bug where
///     [rootPath] was accidentally set to the current scan directory instead of
///     the collection root).
///   * [absPath] — absolute path of the file or folder being processed.
class ScannerPathHelper {
  ScannerPathHelper._(); // no instances

  /// Normalise an absolute path by stripping a trailing slash (unless the path
  /// is just "/").
  static String normalisePath(String path) {
    if (path.length > 1 && path.endsWith('/')) {
      return path.substring(0, path.length - 1);
    }
    return path;
  }

  /// Return the relative path of [absPath] from [collectionRoot].
  ///
  /// If the result happens to be "." (i.e. absPath == collectionRoot), the
  /// method returns the basename of [absPath] for files, or '' for folders.
  static String relativePath(String absPath, String collectionRoot,
      {bool isFolder = false}) {
    absPath = normalisePath(absPath);
    collectionRoot = normalisePath(collectionRoot);

    final rel = p.relative(absPath, from: collectionRoot);
    if (rel == '.') {
      return isFolder ? '' : p.basename(absPath);
    }
    return rel;
  }

  /// Return the relative path of the *parent directory* of [absPath] from
  /// [collectionRoot].
  ///
  /// Returns '' when the parent is the collection root itself (i.e. the item
  /// lives at the top level of the collection).
  static String relativeParent(String absPath, String collectionRoot) {
    absPath = normalisePath(absPath);
    collectionRoot = normalisePath(collectionRoot);

    final parentAbs = p.dirname(absPath);
    final rel = p.relative(parentAbs, from: collectionRoot);
    return rel == '.' ? '' : rel;
  }

  /// Build the canonical database `id` for a collection item.
  ///
  /// Format: `<collectionId>:<relPath>`
  /// For root-level items the id becomes `<collectionId>:` … which is unusual
  /// but consistent.  The caller should prefer always using [relativePath] with
  /// a non-empty result.
  static String buildId(String collectionId, String relPath) {
    return '$collectionId:$relPath';
  }
}
