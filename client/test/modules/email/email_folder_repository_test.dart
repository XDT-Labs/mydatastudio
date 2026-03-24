import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/modules/email/services/email_folder_repository.dart';

void main() {
  late AppDatabase database;
  late EmailFolderRepository repository;

  setUp(() async {
    // Use an in-memory database for testing
    database = AppDatabase(NativeDatabase.memory());
    repository = EmailFolderRepository(database);

    // Need to insert a collection because of foreign key constraint in EmailFolders table
    await database.into(database.collections).insert(
          CollectionsCompanion.insert(
            id: 'col1',
            name: 'Test Account',
            path: 'test@gmail.com',
            type: 'email',
            scanner: 'gmail',
            scanStatus: 'idle',
            needsReAuth: false,
          ),
        );
  });

  tearDown(() async {
    await database.close();
  });

  test('upsertFolder and byCollectionId works correctly', () async {
    final folder = EmailFolder(
      id: 'INBOX',
      collectionId: 'col1',
      name: 'Inbox',
      messagesTotal: 10,
      messagesUnread: 2,
    );

    await repository.upsertFolder(folder);

    final folders = await repository.byCollectionId('col1');
    expect(folders.length, 1);
    expect(folders.first.id, 'INBOX');
    expect(folders.first.name, 'Inbox');
    expect(folders.first.messagesUnread, 2);
    expect(folders.first.messagesTotal, 10);
  });

  test('upsertFolders (batch) works correctly', () async {
    final folders = [
      EmailFolder(id: 'INBOX', collectionId: 'col1', name: 'Inbox'),
      EmailFolder(id: 'SENT', collectionId: 'col1', name: 'Sent'),
    ];

    await repository.upsertFolders(folders);

    final result = await repository.byCollectionId('col1');
    expect(result.length, 2);
    expect(result.any((f) => f.id == 'SENT'), true);
    expect(result.any((f) => f.id == 'INBOX'), true);
  });

  test('deleteFolders works correctly', () async {
    await repository.upsertFolder(
      EmailFolder(id: 'INBOX', collectionId: 'col1', name: 'Inbox'),
    );

    // Verify it's there
    var beforeDelete = await repository.byCollectionId('col1');
    expect(beforeDelete.length, 1);

    // Delete
    await repository.deleteFolders('col1');

    // Verify it's gone
    final afterDelete = await repository.byCollectionId('col1');
    expect(afterDelete.isEmpty, true);
  });
}
