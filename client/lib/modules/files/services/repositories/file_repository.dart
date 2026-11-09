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
import 'package:resqlite/resqlite.dart';

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
      "SELECT * FROM files WHERE collection_id = ? AND parent = ? AND is_deleted = 0 AND is_user_deleted = 0 ORDER BY name LIMIT ? OFFSET ?",
      [collectionId, path, limit, offset],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  Future<File?> create(File f) async {
    await db.execute(
      "INSERT INTO files (id, name, path, parent, date_created, date_last_modified, "
      "last_scanned_date, collection_id, content_type, size, is_deleted, thumbnail, "
      "download_url, email_id, latitude, longitude, local_path, content_id, is_inline, "
      "is_hidden, is_user_deleted) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
        f.isHidden ? 1 : 0,
        f.isUserDeleted ? 1 : 0,
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
        collection != null ? FilePathResolver.absolute(f, collection) : f.path;
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
    bool keepDeleted = false,
  }) async {
    String searchPath = scannedPath;
    if (!searchPath.endsWith('/')) {
      searchPath += '/';
    }

    // keepDeleted: record when the source lost the file instead of hiding it.
    String query =
        keepDeleted
            ? "UPDATE files SET source_deleted_date = ? "
                "WHERE source_deleted_date IS NULL AND collection_id = ? "
            : "UPDATE files SET is_deleted = 1 WHERE collection_id = ? ";
    List<dynamic> args = [
      if (keepDeleted) DateTime.now().millisecondsSinceEpoch,
      collectionId,
    ];

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

  /// Applies source-side removals reported by a change feed. Matches rows by
  /// [itemIds] (file row ids) or by [parentIds] (provider folder ids whose
  /// contents left the collection). With [keepDeleted] the rows stay visible
  /// and only `source_deleted_date` is set, and folder rows are kept so the
  /// kept files remain browsable; otherwise files are marked `is_deleted` and
  /// matching folder rows are removed.
  ///
  /// Ids are applied in chunks inside one transaction to stay under SQLite's
  /// bound-parameter limit.
  Future<void> applyCloudRemovals(
    String collectionId, {
    required List<String> itemIds,
    required List<String> parentIds,
    required bool keepDeleted,
    required DateTime at,
    int chunkSize = 500,
  }) async {
    if (itemIds.isEmpty && parentIds.isEmpty) return;
    String marks(int n) => List.filled(n, '?').join(',');
    Iterable<List<String>> chunks(List<String> l) sync* {
      for (var i = 0; i < l.length; i += chunkSize) {
        yield l.sublist(i, i + chunkSize > l.length ? l.length : i + chunkSize);
      }
    }

    await db.transaction((tx) async {
      for (final (column, ids) in [('id', itemIds), ('parent', parentIds)]) {
        for (final chunk in chunks(ids)) {
          if (keepDeleted) {
            await tx.execute(
              "UPDATE files SET source_deleted_date = ? "
              "WHERE collection_id = ? AND source_deleted_date IS NULL "
              "AND $column IN (${marks(chunk.length)})",
              [at.millisecondsSinceEpoch, collectionId, ...chunk],
            );
          } else {
            await tx.execute(
              "UPDATE files SET is_deleted = 1 WHERE collection_id = ? "
              "AND $column IN (${marks(chunk.length)})",
              [collectionId, ...chunk],
            );
          }
        }
      }
      if (!keepDeleted) {
        for (final chunk in chunks(itemIds)) {
          await tx.execute(
            "DELETE FROM folders WHERE collection_id = ? "
            "AND id IN (${marks(chunk.length)})",
            [collectionId, ...chunk],
          );
        }
      }
    });
  }

  /// Inserts or updates [fileList] in one transaction.
  ///
  /// With [replaceChangedContent] (cloud syncs), a stored row whose content
  /// changed at the source loses its local copy and everything indexed from
  /// the old bytes — see [_dropStaleContent]. Off by default: other scanners
  /// own `local_path` differently and never pass content they did not re-read.
  Future<void> upsertAll(
    List<File> fileList, {
    bool replaceChangedContent = false,
  }) async {
    if (fileList.isEmpty) return;

    await db.transaction((tx) async {
      for (final f in fileList) {
        if (replaceChangedContent) await _dropStaleContent(tx, f);
        await tx.execute(
          "INSERT INTO files (id, name, path, parent, date_created, date_last_modified, "
          "last_scanned_date, collection_id, content_type, size, is_deleted, thumbnail, "
          "download_url, email_id, latitude, longitude, local_path, content_id, is_inline, "
          "is_hidden, is_user_deleted, content_hash, is_online_only) "
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
          // is_hidden and is_user_deleted are absent from the DO UPDATE clause
          // on purpose. The
          // importer sets it once to keep spacer GIFs and banners out of the
          // gallery, but after that it belongs to the user: re-applying it on
          // every scan would undo an un-hide, which is the same bug that made
          // is_deleted unusable for this.
          "ON CONFLICT(id) DO UPDATE SET "
          "name = excluded.name, "
          "path = excluded.path, "
          "parent = excluded.parent, "
          "date_last_modified = excluded.date_last_modified, "
          "last_scanned_date = excluded.last_scanned_date, "
          "size = excluded.size, "
          "content_type = excluded.content_type, "
          // COALESCE, not a plain overwrite: scanners enqueue thumbnail
          // generation as a background job that writes the key with its own
          // `UPDATE files SET thumbnail = ?`, but the row itself doesn't land
          // until the surrounding 100-file batch flushes. Whichever order those
          // two race in, a plain `excluded.thumbnail` loses the key — the batch
          // carries null for any file whose thumbnail hasn't been generated yet.
          // Safe because the cache key is a hash of the file id, so a
          // regenerated thumbnail always reuses the same key and overwrites the
          // same path; keeping the old value can never leave a stale pointer.
          "thumbnail = COALESCE(excluded.thumbnail, files.thumbnail), "
          "download_url = excluded.download_url, "
          "email_id = excluded.email_id, "
          "latitude = excluded.latitude, "
          "longitude = excluded.longitude, "
          "content_id = excluded.content_id, "
          "is_inline = excluded.is_inline, "
          // COALESCE: a scanner that did not hash this time (cache hit on a
          // row it loaded without the hash, or a source that cannot supply
          // one) must not erase a hash an earlier scan computed.
          "content_hash = COALESCE(excluded.content_hash, files.content_hash), "
          "is_online_only = excluded.is_online_only, "
          "is_deleted = 0, "
          // Back at the source (restored from trash, or moved back in).
          "source_deleted_date = NULL",
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
            f.isHidden ? 1 : 0,
            f.isUserDeleted ? 1 : 0,
            f.contentHash,
            f.isOnlineOnly ? 1 : 0,
          ],
        );
      }
    });
  }

  /// Drops what the stored row of [f] derived from content the source no
  /// longer has, when [f] says that content changed.
  ///
  /// Clearing `local_path` puts the file back on the download queue (the
  /// downloader overwrites the old copy). Deleting its embeddings and chunks
  /// and nulling its description — with the attempt budgets reset, since the
  /// new bytes have not failed anything — puts it back on every indexing queue
  /// in `DatabaseRepository`, which select on exactly those being absent.
  /// Tags and landmarks are left alone: user tags share the table.
  ///
  /// Matching content hashes win over a new modified time: Drive bumps the
  /// time on a rename, which changes nothing derived from the bytes. Without
  /// both hashes, a different modified time or size counts as a change.
  Future<void> _dropStaleContent(Transaction tx, File f) async {
    final rows = await tx.select(
      'SELECT date_last_modified, size, content_hash FROM files WHERE id = ?',
      [f.id],
    );
    if (rows.isEmpty) return;
    final stored = rows.single;
    final storedHash = stored['content_hash'] as String?;
    final changed =
        storedHash != null && f.contentHash != null
            ? storedHash != f.contentHash
            : stored['date_last_modified'] !=
                    f.dateLastModified.millisecondsSinceEpoch ||
                stored['size'] != f.size;
    if (!changed) return;

    await tx.execute(
      'UPDATE files SET local_path = NULL, description = NULL, '
      'embedding_attempts = 0, description_attempts = 0 WHERE id = ?',
      [f.id],
    );
    await tx.execute('DELETE FROM files_embeddings WHERE file_id = ?', [f.id]);
    await tx.execute('DELETE FROM file_chunks WHERE file_id = ?', [f.id]);
  }

  /// Other live files with the same bytes as [f] — in any collection.
  /// Empty when [f] has not been hashed.
  Future<List<File>> duplicatesOf(File f) async {
    final hash = f.contentHash;
    if (hash == null) return [];
    final rows = await db.select(
      "SELECT * FROM files WHERE content_hash = ? AND id <> ? "
      "AND is_deleted = 0 AND is_user_deleted = 0 ORDER BY id",
      [hash, f.id],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  /// Every set of two or more live files sharing a content hash, keyed by hash.
  Future<Map<String, List<File>>> duplicateGroups() async {
    final rows = await db.select(
      "SELECT * FROM files WHERE is_deleted = 0 AND is_user_deleted = 0 "
      "AND content_hash IN (SELECT content_hash FROM files "
      "WHERE content_hash IS NOT NULL AND is_deleted = 0 AND is_user_deleted = 0 "
      "GROUP BY content_hash HAVING COUNT(*) > 1) ORDER BY content_hash, id",
    );
    final groups = <String, List<File>>{};
    for (final r in rows) {
      final file = File.fromDbMap(r);
      groups.putIfAbsent(file.contentHash!, () => []).add(file);
    }
    return groups;
  }

  Future<List<File>> getByEmailId(String emailId) async {
    final rows = await db.select(
      "SELECT * FROM files WHERE email_id = ? AND is_deleted = 0 AND is_user_deleted = 0",
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
        "${includeDeleted ? '' : ' AND is_deleted = 0 AND is_user_deleted = 0'}",
        chunk,
      );
      files.addAll(rows.map((r) => File.fromDbMap(r)));
    }
    return files;
  }

  /// Files of a collection that are still at the source and not deleted by
  /// the user.
  Future<List<File>> getLiveFiles(String collectionId) async {
    final rows = await db.select(
      "SELECT * FROM files WHERE collection_id = ? AND is_deleted = 0 AND is_user_deleted = 0 AND source_deleted_date IS NULL",
      [collectionId],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  Future<List<File>> getFilesToDownload(String collectionId) async {
    final rows = await db.select(
      "SELECT * FROM files WHERE collection_id = ? AND local_path IS NULL AND is_deleted = 0 AND is_user_deleted = 0 AND source_deleted_date IS NULL",
      [collectionId],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  /// Live files of a collection that have no thumbnail yet.
  Future<List<File>> getFilesWithoutThumbnail(String collectionId) async {
    final rows = await db.select(
      "SELECT * FROM files WHERE collection_id = ? AND thumbnail IS NULL AND is_deleted = 0 AND is_user_deleted = 0 AND source_deleted_date IS NULL",
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
