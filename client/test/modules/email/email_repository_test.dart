import 'dart:io' as io;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/file.dart' as model;
import 'package:path/path.dart' as p;

void main() {
  late AppDatabase database;
  late EmailRepository repository;
  late String tempDirPath;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = EmailRepository(database);
    
    final tempDir = await io.Directory.systemTemp.createTemp('email_repo_test');
    tempDirPath = tempDir.path;

    // Insert a collection
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
    final tempDir = io.Directory(tempDirPath);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('deleteEmails deletes emails and associated files from DB and filesystem', () async {
    // 1. Setup data
    final emailId1 = 'email1';
    final emailId2 = 'email2';
    
    await database.into(database.emails).insert(
      Email(
        id: emailId1,
        collectionId: 'col1',
        date: DateTime.now(),
        from: 'sender@test.com',
        to: ['recipient@test.com'],
        subject: 'Subject 1',
        isDeleted: false,
      ),
    );
    await database.into(database.emails).insert(
      Email(
        id: emailId2,
        collectionId: 'col1',
        date: DateTime.now(),
        from: 'sender@test.com',
        to: ['recipient@test.com'],
        subject: 'Subject 2',
        isDeleted: false,
      ),
    );

    // Create physical files
    final filePath1 = p.join(tempDirPath, 'file1.txt');
    final filePath2 = p.join(tempDirPath, 'file2.txt');
    await io.File(filePath1).writeAsString('content 1');
    await io.File(filePath2).writeAsString('content 2');

    // Insert file entries in DB
    await database.into(database.files).insert(
      model.File(
        id: 'file1',
        collectionId: 'col1',
        name: 'file1.txt',
        path: filePath1,
        parent: tempDirPath,
        emailId: emailId1,
        isDeleted: false,
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        size: 10,
        contentType: 'text/plain',
      ),
    );
    await database.into(database.files).insert(
      model.File(
        id: 'file2',
        collectionId: 'col1',
        name: 'file2.txt',
        path: filePath2,
        parent: tempDirPath,
        emailId: emailId2,
        isDeleted: false,
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        size: 10,
        contentType: 'text/plain',
      ),
    );

    // Verify they exist
    expect(await io.File(filePath1).exists(), true);
    expect(await io.File(filePath2).exists(), true);
    
    final dbEmailsBefore = await (database.select(database.emails)).get();
    expect(dbEmailsBefore.length, 2);
    
    final dbFilesBefore = await (database.select(database.files)).get();
    expect(dbFilesBefore.length, 2);

    // 2. Execute delete
    await repository.deleteEmails([emailId1, emailId2]);

    // 3. Verify results
    // DB
    final dbEmailsAfter = await (database.select(database.emails)).get();
    expect(dbEmailsAfter.isEmpty, true);
    
    final dbFilesAfter = await (database.select(database.files)).get();
    expect(dbFilesAfter.isEmpty, true);

    // Filesystem
    expect(await io.File(filePath1).exists(), false);
    expect(await io.File(filePath2).exists(), false);
  });
}
