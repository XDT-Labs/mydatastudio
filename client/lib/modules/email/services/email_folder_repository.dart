import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email_folder.dart';

class EmailFolderRepository {
  final AppDatabase database;

  EmailFolderRepository(this.database);

  Future<List<EmailFolder>> byCollectionId(String collectionId) async {
    return await (database.select(database.emailFolders)
          ..where((t) => t.collectionId.equals(collectionId)))
        .get();
  }

  Future<void> upsertFolder(EmailFolder folder) async {
    await database.into(database.emailFolders).insertOnConflictUpdate(folder);
  }

  Future<void> upsertFolders(List<EmailFolder> folders) async {
    await database.batch((batch) {
      batch.insertAllOnConflictUpdate(database.emailFolders, folders);
    });
  }

  Future<void> deleteFolders(String collectionId) async {
    await (database.delete(database.emailFolders)
          ..where((t) => t.collectionId.equals(collectionId)))
        .go();
  }
}
