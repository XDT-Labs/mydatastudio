import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email_folder.dart';

class EmailFolderRepository {
  final AppDatabase database;

  EmailFolderRepository(this.database);

  Future<List<EmailFolder>> byCollectionId(String collectionId) async {
    final rows = await database.select(
      "SELECT * FROM email_folders WHERE collection_id = ?",
      [collectionId],
    );
    return rows.map((r) => EmailFolder.fromDbMap(r)).toList();
  }

  Future<void> upsertFolder(EmailFolder folder) async {
    await database.execute(
      "INSERT OR REPLACE INTO email_folders (id, collection_id, name, type, messages_total, messages_unread, parent_id) "
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [
        folder.id,
        folder.collectionId,
        folder.name,
        folder.type,
        folder.messagesTotal ?? 0,
        folder.messagesUnread ?? 0,
        folder.parentId,
      ],
    );
  }

  Future<void> upsertFolders(List<EmailFolder> folders) async {
    if (folders.isEmpty) return;
    await database.transaction((tx) async {
      for (final folder in folders) {
        await tx.execute(
          "INSERT OR REPLACE INTO email_folders (id, collection_id, name, type, messages_total, messages_unread, parent_id) "
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
          [
            folder.id,
            folder.collectionId,
            folder.name,
            folder.type,
            folder.messagesTotal ?? 0,
            folder.messagesUnread ?? 0,
            folder.parentId,
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
