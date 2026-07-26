import 'dart:io' as io;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// On-disk cache for generated thumbnails.
///
/// Thumbnails live under `<storageRoot>/thumbnails/<collectionId>/<ab>/<hash>.jpg`
/// where `<hash>` is the SHA-1 of the file's DB id (the raw id is
/// `<collectionId>:<relPath>` — not filesystem-safe on its own) and `<ab>` is
/// the first two hex chars of that hash, sharding so a 100k-photo collection
/// doesn't land 100k files in one directory.
///
/// The DB `files.thumbnail` column stores the **relative key**
/// (`<collectionId>/<ab>/<hash>.jpg`), never the bytes — so `SELECT`s stay cheap
/// and moving the storage dir doesn't break references.
class ThumbnailCache {
  /// Absolute path to the `thumbnails` root (`<storageRoot>/thumbnails`).
  final String rootDir;

  ThumbnailCache(String storageRoot)
    : rootDir = p.join(storageRoot, 'thumbnails');

  /// File extension / on-disk format for cached thumbnails. JPEG is the only
  /// format the bundled `image` package can encode (it decodes WebP but can't
  /// encode it), and mirrors what the aiserver returns for RAW files.
  static const String extension = '.jpg';

  /// Relative cache key for a file. Stable across scans for the same id.
  String keyFor(String collectionId, String fileId) {
    final hash = sha1.convert(fileId.codeUnits).toString();
    final shard = hash.substring(0, 2);
    return p.join(collectionId, shard, '$hash$extension');
  }

  io.File fileForKey(String key) => io.File(p.join(rootDir, key));

  /// Whether the given value looks like an on-disk cache key (vs. a remote
  /// `http…` Drive URL or a legacy inline base64 blob). Used by render widgets
  /// to pick the right `ImageProvider`.
  static bool isCacheKey(String? value) =>
      value != null && !value.startsWith('http') && value.endsWith(extension);

  Future<void> writeBytes(String key, List<int> bytes) async {
    final file = fileForKey(key);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  bool existsForKey(String key) => fileForKey(key).existsSync();

  Future<void> deleteKey(String key) async {
    final file = fileForKey(key);
    if (await file.exists()) await file.delete();
  }

  /// Removes every cached thumbnail for a collection (called when the
  /// collection is deleted).
  Future<void> deleteCollection(String collectionId) async {
    final dir = io.Directory(p.join(rootDir, collectionId));
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
