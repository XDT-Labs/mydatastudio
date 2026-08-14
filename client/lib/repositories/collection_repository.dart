import 'dart:io' as io;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/services/credential_codec.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';
import 'package:path/path.dart' as p;

class CollectionRepository {
  final AppDatabase? _db;
  CollectionRepository([this._db]);

  AppDatabase get db => _db ?? DatabaseManager.instance.database!;

  AppLogger logger = AppLogger(null);

  /// Decrypt the OAuth token columns of a just-loaded row in place, so the
  /// returned [Collection] holds plaintext (the in-memory invariant). Only DB
  /// columns ever hold `v1:` ciphertext (AUDIT M2 phase 3/4).
  Collection _fromRow(Map<String, dynamic> row) {
    final c = Collection.fromDbMap(row);
    c.accessToken = CredentialCodec.decrypt(c.accessToken);
    c.refreshToken = CredentialCodec.decrypt(c.refreshToken);
    c.idToken = CredentialCodec.decrypt(c.idToken);
    return c;
  }

  Future<List<Collection>> collections() async {
    final rows = await db.select("SELECT * FROM collections");
    return rows.map(_fromRow).toList();
  }

  Future<List<Collection>> collectionsByType(String type) async {
    final rows = await db.select("SELECT * FROM collections WHERE type = ?", [
      type,
    ]);
    return rows.map(_fromRow).toList();
  }

  Future<Collection?> collectionById(String val) async {
    final rows = await db.select("SELECT * FROM collections WHERE id = ?", [
      val,
    ]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<Collection?> getCollectionByPath(String path) async {
    final rows = await db.select("SELECT * FROM collections WHERE path = ?", [
      path,
    ]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Create new collection
  Future<Collection?> addCollection(Collection val) async {
    return retryOnLock(() async {
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
          CredentialCodec.encrypt(val.accessToken),
          CredentialCodec.encrypt(val.refreshToken),
          CredentialCodec.encrypt(val.idToken),
          val.userId,
          val.expiration?.millisecondsSinceEpoch,
          val.lastScanDate?.millisecondsSinceEpoch,
          val.needsReAuth ? 1 : 0,
          val.downloadLocalCopy ? 1 : 0,
          val.localCopyPath,
        ],
      );
      return val;
    }, label: 'CollectionRepository.addCollection');
  }

  /// Update an existing collection (used for re-auth token refresh)
  Future<Collection?> updateCollection(Collection val) async {
    return retryOnLock(() async {
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
          CredentialCodec.encrypt(val.accessToken),
          CredentialCodec.encrypt(val.refreshToken),
          CredentialCodec.encrypt(val.idToken),
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
    }, label: 'CollectionRepository.updateCollection');
  }

  /// Updates only `scan_status` and `last_scan_date`, by id.
  ///
  /// Scanner isolates relay a scan-completion status update through this
  /// instead of a full [updateCollection]: that call re-encrypts and writes
  /// back every column on the `Collection` object the isolate read at scan
  /// start, including OAuth tokens. If a token refresh landed on a different
  /// connection while the scan was running, a full-object write clobbers it
  /// with the stale value the isolate happened to be holding. A targeted
  /// UPDATE touches only the two columns the scan actually changed.
  Future<void> updateScanStatus(
    String id,
    String status,
    DateTime lastScanDate,
  ) async {
    return retryOnLock(() async {
      await db.execute(
        "UPDATE collections SET scan_status = ?, last_scan_date = ? WHERE id = ?",
        [status, lastScanDate.millisecondsSinceEpoch, id],
      );
    }, label: 'CollectionRepository.updateScanStatus');
  }

  /// Flags [id] as needing reconnection — the single implementation for the
  /// `needs_re_auth = 1` update, shared by every scanner/loader that hits a
  /// dead OAuth refresh token (Gmail, Google Drive scanner, file bytes
  /// loader) so the app's existing reconnect prompt fires instead of the
  /// scan/load failing silently forever.
  Future<void> markNeedsReAuth(String id) async {
    return retryOnLock(() async {
      await db.execute('UPDATE collections SET needs_re_auth = 1 WHERE id = ?', [
        id,
      ]);
    }, label: 'CollectionRepository.markNeedsReAuth');
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

    await retryOnLock(
      () => db.transaction((tx) async {
        final fileRows = await tx.select(
          "SELECT id FROM files WHERE collection_id = ?",
          [id],
        );
        final fileIds = fileRows.map((r) => r['id'] as String).toList();

        if (fileIds.isNotEmpty) {
          final placeholders = List.filled(fileIds.length, '?').join(',');
          await tx.execute(
            "DELETE FROM files_embeddings WHERE file_id IN ($placeholders)",
            fileIds,
          );
        }

        await tx.execute("DELETE FROM files WHERE collection_id = ?", [id]);
        await tx.execute("DELETE FROM folders WHERE collection_id = ?", [id]);
        // Both embedding tables declare ON DELETE CASCADE and resqlite enables
        // PRAGMA foreign_keys on every connection, so deleting the parent rows
        // below would clear them anyway. Deleting a whole collection's vectors
        // as one set operation beats the row-at-a-time cascade over an archive
        // with six figures of mail, which is the only reason these two
        // statements are still here.
        await tx.execute(
          "DELETE FROM emails_embeddings WHERE email_id IN "
          "(SELECT id FROM emails WHERE collection_id = ?)",
          [id],
        );
        await tx.execute("DELETE FROM emails WHERE collection_id = ?", [id]);
        await tx.execute("DELETE FROM email_folders WHERE collection_id = ?", [
          id,
        ]);
        await tx.execute("DELETE FROM collections WHERE id = ?", [id]);
      }),
      label: 'CollectionRepository.deleteCollection',
    );

    // 8. Physical disk cleanup (especially for email attachments/cache)
    String? appDir = MainApp.appDataDirectory.value;
    if (appDir != null) {
      if (collection.type == 'email') {
        try {
          final collectionDiskPath = p.join(
            appDir,
            'files',
            'email',
            collection.id,
          );
          final dir = io.Directory(collectionDiskPath);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            logger.i("Deleted email collection disk path: $collectionDiskPath");
          }
        } catch (e) {
          logger.e("Failed to delete email collection files from disk: $e");
        }
      } else if (collection.type == 'file' &&
          collection.scanner.contains('gdrive')) {
        try {
          // Google Drive files are saved under files/gdrive/{collection.name}
          final collectionDiskPath = p.join(
            appDir,
            'files',
            'gdrive',
            collection.name,
          );
          final dir = io.Directory(collectionDiskPath);
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            logger.i(
              "Deleted GDrive collection disk path: $collectionDiskPath",
            );
          }
        } catch (e) {
          logger.e("Failed to delete GDrive collection files from disk: $e");
        }
      }

      // Remove any cached thumbnails for this collection (all types).
      try {
        await ThumbnailCache(appDir).deleteCollection(id);
      } catch (e) {
        logger.e("Failed to delete cached thumbnails for collection $id: $e");
      }
    }
  }
}
