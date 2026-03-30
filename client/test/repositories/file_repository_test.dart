import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/file.dart' as m;
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileDesktopRepository', () {
    late DatabaseManager databaseManager;
    late FileDesktopRepository repository;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall methodCall) async => ".");

      databaseManager = DatabaseManager.instance;
      databaseManager.useMemoryDb = true;
      databaseManager.appDatabase = AppDatabase(null, null, null, true);
      repository = FileDesktopRepository(databaseManager.database!);
    });

    tearDown(() async {
      await databaseManager.database?.close();
    });

    test('getFilesToDownload should only return files with null localPath and not deleted', () async {
      final collectionId = const Uuid().v4();
      
      // 1. File with localPath (should not be returned)
      final file1 = m.File(
        id: '1',
        name: 'file1.txt',
        path: 'gdrive://1',
        parent: '',
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: collectionId,
        contentType: 'text/plain',
        size: 100,
        isDeleted: false,
        localPath: '/local/path/1',
      );

      // 2. File with null localPath (should be returned)
      final file2 = m.File(
        id: '2',
        name: 'file2.txt',
        path: 'gdrive://2',
        parent: '',
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: collectionId,
        contentType: 'text/plain',
        size: 200,
        isDeleted: false,
        localPath: null,
      );

      // 3. Deleted file with null localPath (should not be returned)
      final file3 = m.File(
        id: '3',
        name: 'file3.txt',
        path: 'gdrive://3',
        parent: '',
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: collectionId,
        contentType: 'text/plain',
        size: 300,
        isDeleted: true,
        localPath: null,
      );

      // 4. File from different collection (should not be returned)
      final file4 = m.File(
        id: '4',
        name: 'file4.txt',
        path: 'gdrive://4',
        parent: '',
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: 'other-collection',
        contentType: 'text/plain',
        size: 400,
        isDeleted: false,
        localPath: null,
      );

      final db = databaseManager.database!;
      await db.into(db.files).insert(file1);
      await db.into(db.files).insert(file2);
      await db.into(db.files).insert(file3);
      await db.into(db.files).insert(file4);

      final results = await repository.getFilesToDownload(collectionId);

      expect(results.length, equals(1));
      expect(results[0].id, equals('2'));
    });
  });
}
