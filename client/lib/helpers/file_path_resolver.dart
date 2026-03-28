import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:path/path.dart' as p;

/// Resolves the absolute filesystem path for a [FileAsset] given its [Collection].
///
/// Files and folders are stored with relative paths in the database (relative
/// to [Collection.localCopyPath]). This helper reconstructs the absolute path
/// needed for actual filesystem operations without any extra DB queries.
///
/// ## Rules
/// - Cloud paths starting with `gdrive://` pass through unchanged.
/// - Paths that are already absolute (start with `/`) pass through unchanged.
/// - For local files: `localCopyPath + '/' + asset.path`.
/// - Falls back to `collection.path` when `localCopyPath` is null (legacy or
///   cloud/email collections that predate this field).
class FilePathResolver {
  const FilePathResolver._();

  /// Returns the absolute path for [asset] in the context of [collection].
  static String absolute(FileAsset asset, Collection collection) {
    return absoluteFromPath(asset.path, collection);
  }

  /// Returns the absolute path for a raw [relativePath] and [collection].
  /// Useful when you have the path string but not the full [FileAsset] object.
  static String absoluteFromPath(String relativePath, Collection collection) {
    // Cloud or already-absolute paths pass through unchanged.
    if (relativePath.startsWith('gdrive://') ||
        relativePath.startsWith('/') ||
        relativePath.isEmpty) {
      return relativePath;
    }

    // Google Drive folders store their ID as the path, which is absolute
    if (collection.scanner == AppConstants.scannerFileGDrive) {
      return relativePath; 
    }

    final root = collection.localCopyPath ?? collection.path;
    if (root.isEmpty) return relativePath;
    return p.join(root, relativePath);
  }
}
