// [ignoring loop detection]
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';

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
      "download_url, email_id, latitude, longitude, local_path) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
      ],
    );
    return f;
  }

  Future<File?> update(File f) async {
    await db.execute(
      "UPDATE files SET "
      "name = ?, path = ?, parent = ?, date_created = ?, date_last_modified = ?, "
      "last_scanned_date = ?, collection_id = ?, content_type = ?, size = ?, is_deleted = ?, "
      "thumbnail = ?, download_url = ?, email_id = ?, latitude = ?, longitude = ?, local_path = ? "
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
        f.id,
      ],
    );
    return f;
  }

  Future<File?> delete(File f) async {
    await db.execute("DELETE FROM files WHERE id = ?", [f.id]);
    return null;
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
          "download_url, email_id, latitude, longitude, local_path) "
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
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

  Future<List<File>> getByEmailIds(List<String> emailIds) async {
    if (emailIds.isEmpty) return [];
    final placeholders = List.filled(emailIds.length, '?').join(',');
    final rows = await db.select(
      "SELECT * FROM files WHERE email_id IN ($placeholders) AND is_deleted = 0",
      emailIds,
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
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
