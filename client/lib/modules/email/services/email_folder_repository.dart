import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';

class EmailFolderRepository {
  final AppDatabase database;

  EmailFolderRepository(this.database);

  /// An upsert rather than INSERT OR REPLACE: REPLACE deletes the row first,
  /// which would null the per-folder sync state on every folder-list refresh.
  /// Null incoming sync state keeps what is stored.
  static const _upsertSql =
      "INSERT INTO email_folders (id, collection_id, name, type, messages_total, "
      "messages_unread, parent_id, path, uid_validity, uid_next, highest_modseq, "
      "last_synced_uid) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
      "ON CONFLICT(id, collection_id) DO UPDATE SET "
      "name = excluded.name, type = excluded.type, "
      "messages_total = excluded.messages_total, "
      "messages_unread = excluded.messages_unread, "
      "parent_id = excluded.parent_id, "
      "path = COALESCE(excluded.path, path), "
      "uid_validity = COALESCE(excluded.uid_validity, uid_validity), "
      "uid_next = COALESCE(excluded.uid_next, uid_next), "
      "highest_modseq = COALESCE(excluded.highest_modseq, highest_modseq), "
      "last_synced_uid = COALESCE(excluded.last_synced_uid, last_synced_uid)";

  Future<List<EmailFolder>> byCollectionId(String collectionId) async {
    final rows = await database.select(
      "SELECT * FROM email_folders WHERE collection_id = ?",
      [collectionId],
    );
    return rows.map((r) => EmailFolder.fromDbMap(r)).toList();
  }

  Future<void> upsertFolder(EmailFolder folder) async {
    await database.execute(
      _upsertSql,
      [
        folder.id,
        folder.collectionId,
        folder.name,
        folder.type,
        folder.messagesTotal ?? 0,
        folder.messagesUnread ?? 0,
        folder.parentId,
        folder.path,
        folder.uidValidity,
        folder.uidNext,
        folder.highestModseq,
        folder.lastSyncedUid,
      ],
    );
  }

  Future<void> upsertFolders(List<EmailFolder> folders) async {
    if (folders.isEmpty) return;
    await database.transaction((tx) async {
      for (final folder in folders) {
        await tx.execute(
          _upsertSql,
          [
            folder.id,
            folder.collectionId,
            folder.name,
            folder.type,
            folder.messagesTotal ?? 0,
            folder.messagesUnread ?? 0,
            folder.parentId,
            folder.path,
            folder.uidValidity,
            folder.uidNext,
            folder.highestModseq,
            folder.lastSyncedUid,
          ],
        );
      }
    });
  }

  Future<void> deleteFolders(String collectionId) async {
    await database.execute(
      "DELETE FROM email_folders WHERE collection_id = ?",
      [collectionId],
    );
  }
}
