import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/repositories/user_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/files/services/repositories/folder_repository.dart';

import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/repositories/aichat_model_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Database & Repositories SQL Integration Tests', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();

      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_test_');

      const MethodChannel channel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall methodCall) async {
        return tempDir.path;
      });

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('check instance and db is not null', () {
      expect(databaseManager, isNotNull);
      expect(databaseManager.database, isNotNull);
    });

    test('check database tables exist by query', () async {
      final db = databaseManager.database!;
      final rows = await db.select(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final tableNames = rows.map((r) => r['name'] as String).toList();

      expect(tableNames.contains('app_users'), isTrue);
      expect(tableNames.contains('collections'), isTrue);
      expect(tableNames.contains('files'), isTrue);
      expect(tableNames.contains('folders'), isTrue);
      expect(tableNames.contains('files_embeddings'), isTrue);
    });

    test('UserRepository CRUD Integration', () async {
      final db = databaseManager.database!;
      final repo = UserRepository(db);

      final user = AppUser(
        id: const Uuid().v4(),
        name: 'John Doe',
        email: 'john@example.com',
        password: 'hashed_password_123',
        localStoragePath: '.',
      );

      // Save user
      await repo.saveUser(user);

      // Read users
      final usersList = await repo.users();
      expect(usersList.length, equals(1));
      expect(usersList.first.name, equals('John Doe'));

      // Find by password
      final exists = await repo.userExists();
      expect(exists, isNotNull);
      expect(exists!.id, equals(user.id));
    });

    test('CollectionRepository CRUD Integration', () async {
      final db = databaseManager.database!;
      final repo = CollectionRepository(db);

      final col = Collection(
        id: const Uuid().v4(),
        name: 'My Drive',
        path: '/drive',
        type: 'file',
        scanner: 'gdrive',
        needsReAuth: false,
        scanStatus: 'idle',
      );

      // Add collection
      await repo.addCollection(col);

      // Fetch collections
      final cols = await repo.collections();
      expect(cols.length, equals(1));
      expect(cols.first.name, equals('My Drive'));

      // Fetch by ID
      final fetched = await repo.collectionById(col.id);
      expect(fetched, isNotNull);
      expect(fetched!.name, equals('My Drive'));
    });

    test('FileDesktopRepository Integration', () async {
      final db = databaseManager.database!;
      final repo = FileDesktopRepository(db);

      final file = File(
        id: const Uuid().v4(),
        name: 'photo.jpg',
        path: '/photos/photo.jpg',
        parent: '/photos',
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: 'col-123',
        contentType: 'image/jpeg',
        size: 1024,
        isDeleted: false,
      );

      // Create file
      await repo.create(file);

      // Get by parent path
      final files = await repo.getByParentPath('col-123', '/photos');
      expect(files.length, equals(1));
      expect(files.first.name, equals('photo.jpg'));

      // Get by ID / path
      final fetched = await repo.getByPath(file);
      expect(fetched, isNotNull);
      expect(fetched!.name, equals('photo.jpg'));
    });

    test('FolderDesktopRepository Integration', () async {
      final db = databaseManager.database!;
      final repo = FolderDesktopRepository(db);

      final folder = Folder(
        id: const Uuid().v4(),
        name: 'Photos',
        path: '/photos',
        parent: '/',
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: 'col-123',
      );

      // Create folder
      await repo.create(folder);

      // Get by parent path
      final folders = await repo.getByParentPath('col-123', '/');
      expect(folders.length, equals(1));
      expect(folders.first.name, equals('Photos'));
    });

    test('DatabaseRepository Embeddings Routing & Queries', () async {
      final db = databaseManager.database!;
      final dbRepo = DatabaseRepository(db);
      final fileRepo = FileDesktopRepository(db);
      final colRepo = CollectionRepository(db);

      // Setup a collection
      final colId = const Uuid().v4();
      final col = Collection(
        id: colId,
        name: 'Photos Collection',
        path: '/photos',
        type: 'file',
        scanner: 'local',
        needsReAuth: false,
        scanStatus: 'idle',
      );
      await colRepo.addCollection(col);

      // Create dummy image file
      final fileId = const Uuid().v4();
      final file = File(
        id: fileId,
        name: 'test_img.png',
        path: 'test_img.png',
        parent: '/photos',
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: colId,
        contentType: 'application/image',
        size: 2048,
        isDeleted: false,
      );
      await fileRepo.create(file);

      // Initially, the file has missing embeddings (none exists)
      var missing = await dbRepo.getFilesWithMissingEmbeddings(limit: 10);
      expect(missing.any((f) => f.id == fileId), isTrue);
      expect(missing.firstWhere((f) => f.id == fileId).path, equals('/photos/test_img.png'));

      // Upsert a 2048-dimension embedding (Qwen3-VL)
      final embedding = List<double>.filled(2048, 0.5);
      await dbRepo.upsertFileEmbedding(fileId, embedding);

      // Check database to ensure qwen3_vl_embedding is populated
      var rows = await db.select(
        'SELECT qwen3_vl_embedding FROM files_embeddings WHERE file_id = ?',
        [fileId],
      );
      expect(rows, isNotEmpty);
      expect(rows.first['qwen3_vl_embedding'], isNotNull);

      // Now the embedding is present, so getFilesWithMissingEmbeddings should NOT return it
      missing = await dbRepo.getFilesWithMissingEmbeddings(limit: 10);
      expect(missing.any((f) => f.id == fileId), isFalse);

      // Clean up/delete embedding
      await dbRepo.deleteFileEmbedding(fileId);
      rows = await db.select('SELECT * FROM files_embeddings WHERE file_id = ?', [fileId]);
      expect(rows, isEmpty);
    });

    test('AichatModelRepository Ollama model initialization and update', () async {
      final db = databaseManager.database!;
      final repo = AichatModelRepository(db);

      // Fetch all models
      final models = await repo.getAll();
      final ollamaModel = models.firstWhere((m) => m.group == 'ollama');

      // Verify default is disabled and has null base_url
      expect(ollamaModel.baseUrl, isNull);
      expect(ollamaModel.enabled, isFalse);

      // Verify setBaseUrl and setEnabled
      await repo.setBaseUrl(ollamaModel.id, 'http://localhost:11434');
      await repo.setEnabled(ollamaModel.id, true);

      final updatedModels = await repo.getAll();
      final updatedOllama = updatedModels.firstWhere((m) => m.id == ollamaModel.id);
      expect(updatedOllama.baseUrl, equals('http://localhost:11434'));
      expect(updatedOllama.enabled, isTrue);
    });
  });
}
