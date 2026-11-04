import 'dart:io' as io;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/modules/search/services/email_contact_repository.dart';
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
        "needs_re_auth, download_local_copy, local_copy_path, keep_deleted_files, content_policy, "
        "email_provider_id, imap_settings, email_delete_policy, date_created) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
          val.keepDeletedFiles ? 1 : 0,
          val.contentPolicy,
          val.emailProviderId,
          val.imapSettings,
          val.emailDeletePolicy.dbValue,
          (val.dateCreated ?? DateTime.now()).millisecondsSinceEpoch,
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
        "download_local_copy = ?, local_copy_path = ?, keep_deleted_files = ?, content_policy = ?, "
        "email_provider_id = ?, imap_settings = ?, email_delete_policy = ? "
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
          val.keepDeletedFiles ? 1 : 0,
          val.contentPolicy,
          val.emailProviderId,
          val.imapSettings,
          val.emailDeletePolicy.dbValue,
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
    DateTime? lastScanDate,
  ) async {
    return retryOnLock(() async {
      // A null date leaves last_scan_date untouched (e.g. recording an error).
      if (lastScanDate == null) {
        await db.execute("UPDATE collections SET scan_status = ? WHERE id = ?", [
          status,
          id,
        ]);
        return;
      }
      await db.execute(
        "UPDATE collections SET scan_status = ?, last_scan_date = ? WHERE id = ?",
        [status, lastScanDate.millisecondsSinceEpoch, id],
      );
    }, label: 'CollectionRepository.updateScanStatus');
  }

  /// Sets only `email_delete_policy` for [collectionId]. A targeted UPDATE, so
  /// a settings dialog holding a stale Collection cannot overwrite tokens or
  /// other columns a scanner changed meanwhile.
  Future<void> updateEmailDeletePolicy(
    String collectionId,
    EmailDeletePolicy policy,
  ) async {
    return retryOnLock(() async {
      await db.execute(
        'UPDATE collections SET email_delete_policy = ? WHERE id = ?',
        [policy.dbValue, collectionId],
      );
    }, label: 'CollectionRepository.updateEmailDeletePolicy');
  }

  /// Sets only the OAuth token columns (access, refresh, expiration) for [id].
  /// A targeted UPDATE so a refresh in a scanner isolate cannot clobber other
  /// columns a concurrent writer changed. Tokens are encrypted here.
  Future<void> updateOAuthTokens(
    String id, {
    required String accessToken,
    required String refreshToken,
    required DateTime expiration,
  }) async {
    return retryOnLock(() async {
      await db.execute(
        'UPDATE collections SET access_token = ?, refresh_token = ?, '
        'expiration = ? WHERE id = ?',
        [
          CredentialCodec.encrypt(accessToken),
          CredentialCodec.encrypt(refreshToken),
          expiration.millisecondsSinceEpoch,
          id,
        ],
      );
    }, label: 'CollectionRepository.updateOAuthTokens');
  }

  /// Stores (or, with null, clears) the provider change-feed position. A
  /// targeted UPDATE for the same reason as [updateScanStatus].
  Future<void> setChangeCursor(String id, String? cursor) async {
    return retryOnLock(() async {
      await db.execute('UPDATE collections SET change_cursor = ? WHERE id = ?', [
        cursor,
        id,
      ]);
    }, label: 'CollectionRepository.setChangeCursor');
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
        for (final path in _diskPathsOf(collection)) {
          await tx.execute(
            "INSERT OR IGNORE INTO pending_disk_deletes (path) VALUES (?)",
            [path],
          );
        }
      }),
      label: 'CollectionRepository.deleteCollection',
    );

    await deletePendingDiskPaths();

    // Contact counts can't say which account an address came from, so only a
    // rebuild removes the ones that came solely from this one. Non-fatal: the
    // account is already gone, and this only feeds search suggestions.
    if (collection.type == 'email') {
      try {
        await EmailContactRepository(db).backfillFromEmails();
      } catch (e) {
        logger.e("Failed to rebuild contacts after deleting $id: $e");
      }
    }
  }

  /// Where [collection]'s files live, relative to the storage root.
  List<String> _diskPathsOf(Collection collection) => [
    if (collection.type == 'email') p.join('files', 'email', collection.id),
    if (collection.type == 'file' && collection.scanner.contains('gdrive'))
      // Google Drive files are saved under files/gdrive/{collection.name}
      p.join('files', 'gdrive', collection.name),
    p.join('thumbnails', collection.id),
  ];

  /// Deletes the folders of deleted collections. A folder stays queued until
  /// it is really gone, and this runs again at startup, so a failure here, or
  /// storage that isn't reachable, doesn't strand files with nothing pointing
  /// at them.
  Future<void> deletePendingDiskPaths() async {
    final appDir = MainApp.appDataDirectory.valueOrNull;
    if (appDir == null || !await io.Directory(appDir).exists()) return;

    final rows = await db.select("SELECT path FROM pending_disk_deletes");
    for (final row in rows) {
      final path = row['path'] as String;
      try {
        final dir = io.Directory(p.join(appDir, path));
        if (await dir.exists()) await dir.delete(recursive: true);
        await db.execute("DELETE FROM pending_disk_deletes WHERE path = ?", [
          path,
        ]);
        logger.i("Deleted collection disk path: $path");
      } catch (e) {
        logger.e("Failed to delete $path from disk, will retry: $e");
      }
    }
  }
}
