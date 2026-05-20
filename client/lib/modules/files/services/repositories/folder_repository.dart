// [ignoring loop detection]
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/folder.dart';

class FolderDesktopRepository {
  AppLogger logger = AppLogger(null);
  AppDatabase db;

  FolderDesktopRepository(this.db);

  Future<Folder?> getByPath(Folder f) async {
    final rows = await db.select(
      "SELECT * FROM folders WHERE path = ? AND collection_id = ? LIMIT 1",
      [f.path, f.collectionId],
    );
    if (rows.isEmpty) return null;
    return Folder.fromDbMap(rows.first);
  }

  Future<List<Folder>> getByParentPath(
    String collectionId,
    String path, {
    int limit = 500,
    int offset = 0,
  }) async {
    final rows = await db.select(
      "SELECT * FROM folders WHERE collection_id = ? AND parent = ? ORDER BY name LIMIT ? OFFSET ?",
      [collectionId, path, limit, offset],
    );
    return rows.map((r) => Folder.fromDbMap(r)).toList();
  }

  Future<Folder?> create(Folder f) async {
    await db.execute(
      "INSERT INTO folders (id, name, path, parent, date_created, date_last_modified, "
      "last_scanned_date, thumbnail, download_url, email_id, collection_id) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        f.id,
        f.name,
        f.path,
        f.parent,
        f.dateCreated.millisecondsSinceEpoch,
        f.dateLastModified.millisecondsSinceEpoch,
        f.lastScannedDate?.millisecondsSinceEpoch,
        f.thumbnail,
        f.downloadUrl,
        f.emailId,
        f.collectionId,
      ],
    );
    return f;
  }

  Future<Folder?> update(Folder f) async {
    await db.execute(
      "UPDATE folders SET "
      "name = ?, path = ?, parent = ?, date_created = ?, date_last_modified = ?, "
      "last_scanned_date = ?, thumbnail = ?, download_url = ?, email_id = ?, collection_id = ? "
      "WHERE id = ?",
      [
        f.name,
        f.path,
        f.parent,
        f.dateCreated.millisecondsSinceEpoch,
        f.dateLastModified.millisecondsSinceEpoch,
        f.lastScannedDate?.millisecondsSinceEpoch,
        f.thumbnail,
        f.downloadUrl,
        f.emailId,
        f.collectionId,
        f.id,
      ],
    );
    return f;
  }

  Future<Folder?> delete(Folder f) async {
    await db.execute("DELETE FROM folders WHERE id = ?", [f.id]);
    return null;
  }

  Future<void> deleteMissing(String collectionId, String scannedPath, DateTime scanStartTime, {bool recursive = true, bool isCloud = false, bool isFullScan = false}) async {
    String searchPath = scannedPath;
    if (!searchPath.endsWith('/')) {
      searchPath += '/';
    }

    String query = "DELETE FROM folders WHERE collection_id = ? ";
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

  Future<void> deleteAllByCollectionId(String collectionId) async {
    await db.execute("DELETE FROM folders WHERE collection_id = ?", [collectionId]);
  }
}
