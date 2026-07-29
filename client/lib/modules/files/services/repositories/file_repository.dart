// [ignoring loop detection]
import 'dart:io' as io;

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/helpers/sql_chunks.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:path/path.dart' as p;

class FileDesktopRepository {
  AppLogger logger = AppLogger(null);
  AppDatabase db;

  FileDesktopRepository(this.db);

  Future<File?> getByPath(File f) async {
    final rows = await db.select("SELECT * FROM files WHERE id = ? LIMIT 1", [
      f.id,
    ]);
    if (rows.isEmpty) return null;
    return File.fromDbMap(rows.first);
  }

  Future<List<File>> getByParentPath(
    String collectionId,
    String path, {
    int limit = 200,
    int offset = 0,
  }) async {
    final rows = await db.select(
      "SELECT * FROM files WHERE collection_id = ? AND parent = ? AND is_deleted = 0 ORDER BY name LIMIT ? OFFSET ?",
      [collectionId, path, limit, offset],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  Future<File?> create(File f) async {
    await db.execute(
      "INSERT INTO files (id, name, path, parent, date_created, date_last_modified, "
      "last_scanned_date, collection_id, content_type, size, is_deleted, thumbnail, "
      "download_url, email_id, latitude, longitude, local_path, content_id, is_inline) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        f.id,
        f.name,
        f.path,
        f.parent,
        f.dateCreated.millisecondsSinceEpoch,
        f.dateLastModified.millisecondsSinceEpoch,
        f.lastScannedDate?.millisecondsSinceEpoch,
        f.collectionId,
        f.contentType,
        f.size,
        f.isDeleted ? 1 : 0,
        f.thumbnail,
        f.downloadUrl,
        f.emailId,
        f.latitude,
        f.longitude,
        f.localPath,
        f.contentId,
        f.isInline ? 1 : 0,
      ],
    );
    return f;
  }

  Future<File?> update(File f) async {
    await db.execute(
      "UPDATE files SET "
      "name = ?, path = ?, parent = ?, date_created = ?, date_last_modified = ?, "
      "last_scanned_date = ?, collection_id = ?, content_type = ?, size = ?, is_deleted = ?, "
      "thumbnail = ?, download_url = ?, email_id = ?, latitude = ?, longitude = ?, local_path = ?, content_id = ?, is_inline = ? "
      "WHERE id = ?",
      [
        f.name,
        f.path,
        f.parent,
        f.dateCreated.millisecondsSinceEpoch,
        f.dateLastModified.millisecondsSinceEpoch,
        f.lastScannedDate?.millisecondsSinceEpoch,
        f.collectionId,
        f.contentType,
        f.size,
        f.isDeleted ? 1 : 0,
        f.thumbnail,
        f.downloadUrl,
        f.emailId,
        f.latitude,
        f.longitude,
        f.localPath,
        f.contentId,
        f.isInline ? 1 : 0,
        f.id,
      ],
    );
    return f;
  }

  Future<File?> delete(File f, {Collection? collection}) async {
    await deleteFiles([f], collection: collection);
    return null;
  }

  /// Permanently removes [files] and every artifact derived from them: the
  /// bytes on disk, the cached thumbnail, the embedding row and the `files`
  /// row itself.
  ///
  /// The embedding goes by cascade — resqlite enables `PRAGMA foreign_keys` on
  /// every connection, so the `ON DELETE CASCADE` on `files_embeddings` fires.
  /// Nothing on disk cascades, which is the part that has to be done here.
  ///
  /// [collection] resolves each row's stored path. Every scanner except the PST
  /// one writes a path *relative* to the collection root, so unlinking
  /// `f.path` directly resolves against the process working directory, finds
  /// nothing, and silently leaves the bytes behind.
  Future<void> deleteFiles(List<File> files, {Collection? collection}) async {
    if (files.isEmpty) return;

    // Disk first, rows second: an unlink that fails is logged and the row still
    // goes, because a file with no row is reachable again by a rescan while a
    // row pointing at nothing is a permanent ghost in the UI.
    for (final f in files) {
      for (final path in _onDiskPaths(f, collection)) {
        try {
          final ioFile = io.File(path);
          if (await ioFile.exists()) await ioFile.delete();
        } catch (err) {
          logger.e("Error deleting file at $path: $err");
        }
      }
      await _deleteThumbnail(f);
    }

    // One transaction, many statements: the id list can exceed SQLite's bound
    // parameter ceiling (see [sqlChunks]), and the rows still have to go as a
    // unit — a half-applied delete is the ghost this method exists to prevent.
    final ids = files.map((f) => f.id).toList();
    await db.transaction((tx) async {
      for (final chunk in sqlChunks(ids)) {
        final placeholders = List.filled(chunk.length, '?').join(',');
        await tx.execute(
          "DELETE FROM files WHERE id IN ($placeholders)",
          chunk,
        );
      }
    });
  }

  /// Absolute paths this row owns on disk. Empty for a cloud row that was never
  /// downloaded — `gdrive://…` is an identifier, not a path.
  Iterable<String> _onDiskPaths(File f, Collection? collection) {
    final paths = <String>{};

    final local = f.localPath;
    if (local != null && local.isNotEmpty) paths.add(local);

    final resolved =
        collection != null
            ? FilePathResolver.absolute(f, collection)
            : f.path;
    if (resolved.startsWith('gdrive://')) return paths;
    if (p.isAbsolute(resolved)) {
      paths.add(resolved);
    } else if (paths.isEmpty) {
      // Relative and nothing to resolve it against: deleting would be a no-op
      // against the working directory, so say so rather than pretend.
      logger.w(
        "Cannot delete '${f.path}' from disk: relative path and no collection "
        "supplied for file ${f.id}",
      );
    }

    return paths;
  }

  Future<void> _deleteThumbnail(File f) async {
    final key = f.thumbnail;
    if (!ThumbnailCache.isCacheKey(key)) return;

    final root = MainApp.appDataDirectory.valueOrNull;
    if (root == null) {
      logger.w(
        "Cannot delete cached thumbnail '$key': app data directory unknown",
      );
      return;
    }
    try {
      await ThumbnailCache(root).deleteKey(key!);
    } catch (err) {
      logger.e("Error deleting cached thumbnail '$key': $err");
    }
  }

  Future<void> markMissingAsDeleted(
    String collectionId,
    String scannedPath,
    DateTime scanStartTime, {
    bool recursive = true,
    bool isCloud = false,
    bool isFullScan = false,
  }) async {
    String searchPath = scannedPath;
    if (!searchPath.endsWith('/')) {
      searchPath += '/';
    }

    String query = "UPDATE files SET is_deleted = 1 WHERE collection_id = ? ";
    List<dynamic> args = [collectionId];

    if (isCloud) {
      if (recursive && isFullScan) {
        // no extra parent condition
      } else {
        query += "AND parent = ? ";
        args.add(scannedPath);
      }
    } else {
      if (recursive) {
        query += "AND (parent = ? OR parent LIKE ?) ";
        args.add(scannedPath);
        args.add('$searchPath%');
      } else {
        query += "AND parent = ? ";
        args.add(scannedPath);
      }
    }

    query += "AND (last_scanned_date IS NULL OR last_scanned_date < ?) ";
    args.add(scanStartTime.millisecondsSinceEpoch);

    await db.execute(query, args);
  }

  Future<void> upsertAll(List<File> fileList) async {
    if (fileList.isEmpty) return;

    await db.transaction((tx) async {
      for (final f in fileList) {
        await tx.execute(
          "INSERT INTO files (id, name, path, parent, date_created, date_last_modified, "
          "last_scanned_date, collection_id, content_type, size, is_deleted, thumbnail, "
          "download_url, email_id, latitude, longitude, local_path, content_id, is_inline) "
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
          "ON CONFLICT(id) DO UPDATE SET "
          "name = excluded.name, "
          "path = excluded.path, "
          "parent = excluded.parent, "
          "date_last_modified = excluded.date_last_modified, "
          "last_scanned_date = excluded.last_scanned_date, "
          "size = excluded.size, "
          "content_type = excluded.content_type, "
          "thumbnail = excluded.thumbnail, "
          "download_url = excluded.download_url, "
          "email_id = excluded.email_id, "
          "content_id = excluded.content_id, "
          "is_inline = excluded.is_inline, "
          "is_deleted = 0",
          [
            f.id,
            f.name,
            f.path,
            f.parent,
            f.dateCreated.millisecondsSinceEpoch,
            f.dateLastModified.millisecondsSinceEpoch,
            f.lastScannedDate?.millisecondsSinceEpoch,
            f.collectionId,
            f.contentType,
            f.size,
            f.isDeleted ? 1 : 0,
            f.thumbnail,
            f.downloadUrl,
            f.emailId,
            f.latitude,
            f.longitude,
            f.localPath,
            f.contentId,
            f.isInline ? 1 : 0,
          ],
        );
      }
    });
  }

  Future<List<File>> getByEmailId(String emailId) async {
    final rows = await db.select(
      "SELECT * FROM files WHERE email_id = ? AND is_deleted = 0",
      [emailId],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  /// Attachments of [emailIds]. [includeDeleted] returns soft-deleted rows too,
  /// which is what a permanent delete wants — those are precisely the rows that
  /// would otherwise outlive the message they belong to.
  Future<List<File>> getByEmailIds(
    List<String> emailIds, {
    bool includeDeleted = false,
  }) async {
    if (emailIds.isEmpty) return [];
    final files = <File>[];
    for (final chunk in sqlChunks(emailIds)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.select(
        "SELECT * FROM files WHERE email_id IN ($placeholders)"
        "${includeDeleted ? '' : ' AND is_deleted = 0'}",
        chunk,
      );
      files.addAll(rows.map((r) => File.fromDbMap(r)));
    }
    return files;
  }

  Future<List<File>> getFilesToDownload(String collectionId) async {
    final rows = await db.select(
      "SELECT * FROM files WHERE collection_id = ? AND local_path IS NULL AND is_deleted = 0",
      [collectionId],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  Future<List<File>> getScanMetadata(String collectionId) async {
    final rows = await db.select(
      "SELECT * FROM files WHERE collection_id = ?",
      [collectionId],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  Future<void> deleteAllByCollectionId(String collectionId) async {
    await db.execute("DELETE FROM files WHERE collection_id = ?", [
      collectionId,
    ]);
  }
}
