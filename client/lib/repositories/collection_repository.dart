import 'dart:io' as io;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:path/path.dart' as p;

class CollectionRepository {
  final AppDatabase? _db;
  CollectionRepository([this._db]);

  AppDatabase get db => _db ?? DatabaseManager.instance.database!;

  AppLogger logger = AppLogger(null);

  Future<List<Collection>> collections() async {
    final rows = await db.select("SELECT * FROM collections");
    return rows.map((r) => Collection.fromDbMap(r)).toList();
  }

  Future<List<Collection>> collectionsByType(String type) async {
    final rows = await db.select("SELECT * FROM collections WHERE type = ?", [type]);
    return rows.map((r) => Collection.fromDbMap(r)).toList();
  }

  Future<Collection?> collectionById(String val) async {
    final rows = await db.select("SELECT * FROM collections WHERE id = ?", [val]);
    if (rows.isEmpty) return null;
    return Collection.fromDbMap(rows.first);
  }

  Future<Collection?> getCollectionByPath(String path) async {
    final rows = await db.select("SELECT * FROM collections WHERE path = ?", [path]);
    if (rows.isEmpty) return null;
    return Collection.fromDbMap(rows.first);
  }

  /// Create new collection
  Future<Collection?> addCollection(Collection val) async {
    await db.execute(
      "INSERT INTO collections (id, name, path, type, scanner, scan_status, oauth_service, "
      "access_token, refresh_token, id_token, user_id, expiration, last_scan_date, "
      "needs_re_auth, download_local_copy, local_copy_path) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        val.id,
        val.name,
        val.path,
        val.type,
        val.scanner,
        val.scanStatus,
        val.oauthService,
        val.accessToken,
        val.refreshToken,
        val.idToken,
        val.userId,
        val.expiration?.millisecondsSinceEpoch,
        val.lastScanDate?.millisecondsSinceEpoch,
        val.needsReAuth ? 1 : 0,
        val.downloadLocalCopy ? 1 : 0,
        val.localCopyPath,
      ],
    );
    return val;
  }

  /// Update an existing collection (used for re-auth token refresh)
  Future<Collection?> updateCollection(Collection val) async {
    await db.execute(
      "UPDATE collections SET "
      "name = ?, path = ?, type = ?, scanner = ?, scan_status = ?, "
      "oauth_service = ?, access_token = ?, refresh_token = ?, id_token = ?, user_id = ?, "
      "expiration = ?, last_scan_date = ?, needs_re_auth = ?, "
      "download_local_copy = ?, local_copy_path = ? "
      "WHERE id = ?",
      [
        val.name,
        val.path,
        val.type,
        val.scanner,
        val.scanStatus,
        val.oauthService,
        val.accessToken,
        val.refreshToken,
        val.idToken,
        val.userId,
        val.expiration?.millisecondsSinceEpoch,
        val.lastScanDate?.millisecondsSinceEpoch,
        val.needsReAuth ? 1 : 0,
        val.downloadLocalCopy ? 1 : 0,
        val.localCopyPath,
        val.id,
      ],
    );
    return val;
  }

  /// Update the scan date for services that check external systems on a schedule, such as email
  void updateLastScanDate(Collection collection, DateTime? value) async {
    collection.lastScanDate = DateTime.now();
    await updateCollection(collection);
  }

  Future<void> deleteCollection(String id) async {
    // 1. Fetch collection info before deleting it
    final collection = await collectionById(id);
    if (collection == null) return;

    await db.transaction((tx) async {
      // 2. Find and delete all file embeddings associated with files in this collection
      final fileRows = await tx.select("SELECT id FROM files WHERE collection_id = ?", [id]);
      final fileIds = fileRows.map((r) => r['id'] as String).toList();
      
      if (fileIds.isNotEmpty) {
        final placeholders = List.filled(fileIds.length, '?').join(',');
        await tx.execute("DELETE FROM files_embeddings WHERE file_id IN ($placeholders)", fileIds);
      }

      // 3. Delete all files linked to this collection
      await tx.execute("DELETE FROM files WHERE collection_id = ?", [id]);

      // 4. Delete all folders linked to this collection
      await tx.execute("DELETE FROM folders WHERE collection_id = ?", [id]);

      // 5. Delete all emails linked to this collection
      await tx.execute("DELETE FROM emails WHERE collection_id = ?", [id]);

      // 6. Delete all email folders linked to this collection
      await tx.execute("DELETE FROM email_folders WHERE collection_id = ?", [id]);

      // 7. Finally delete the collection itself
      await tx.execute("DELETE FROM collections WHERE id = ?", [id]);
    });

    // 8. Physical disk cleanup (especially for email attachments/cache)
    String? appDir = MainApp.appDataDirectory.value;
    if (appDir != null) {
      if (collection.type == 'email') {
        try {
          final collectionDiskPath = p.join(appDir, 'files', 'email', collection.id);
          final dir = io.Directory(collectionDiskPath);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            logger.i("Deleted email collection disk path: $collectionDiskPath");
          }
        } catch (e) {
          logger.e("Failed to delete email collection files from disk: $e");
        }
      } else if (collection.type == 'file' && collection.scanner.contains('gdrive')) {
        try {
          // Google Drive files are saved under files/gdrive/{collection.name}
          final collectionDiskPath = p.join(appDir, 'files', 'gdrive', collection.name);
          final dir = io.Directory(collectionDiskPath);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            logger.i("Deleted GDrive collection disk path: $collectionDiskPath");
          }
        } catch (e) {
          logger.e("Failed to delete GDrive collection files from disk: $e");
        }
      }
    }
  }
}
