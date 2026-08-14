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
      expect(tableNames.contains('emails_embeddings'), isTrue);
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

    group('embedding attempt budget', () {
      late DatabaseRepository dbRepo;
      late String fileId;

      setUp(() async {
        final db = databaseManager.database!;
        dbRepo = DatabaseRepository(db);
        final colRepo = CollectionRepository(db);
        final fileRepo = FileDesktopRepository(db);

        final colId = const Uuid().v4();
        await colRepo.addCollection(
          Collection(
            id: colId,
            name: 'Photos',
            path: '/photos',
            type: 'file',
            scanner: 'local',
            needsReAuth: false,
            scanStatus: 'idle',
          ),
        );

        fileId = const Uuid().v4();
        await fileRepo.create(
          File(
            id: fileId,
            name: 'broken.jpg',
            path: 'broken.jpg',
            parent: '/photos',
            dateCreated: DateTime.now(),
            dateLastModified: DateTime.now(),
            collectionId: colId,
            contentType: 'image/jpeg',
            size: 2048,
            isDeleted: false,
          ),
        );
      });

      test('an image that can never decode eventually leaves the queue', () async {
        // Without this the same file is re-selected every batch forever: the
        // queue never drains, the aiserver decodes the same broken bytes on a
        // loop, and the log fills with identical errors. Seven files were doing
        // exactly this on the dev archive.
        for (var i = 0; i < DatabaseRepository.maxEmbeddingAttempts; i++) {
          final missing = await dbRepo.getFilesWithMissingEmbeddings(limit: 50);
          expect(
            missing.any((f) => f.id == fileId),
            isTrue,
            reason: 'must stay eligible for attempt ${i + 1}',
          );
          await dbRepo.incrementEmbeddingAttempts(fileId);
        }

        final missing = await dbRepo.getFilesWithMissingEmbeddings(limit: 50);
        expect(missing.any((f) => f.id == fileId), isFalse);
      });

      test('a successful embedding clears the budget', () async {
        // The eligibility query re-selects on a model_version change, so a
        // file that once exhausted its attempts and later succeeded would be
        // held back at the next revision bump — silently, because a stale
        // vector is still a vector.
        for (var i = 0; i < DatabaseRepository.maxEmbeddingAttempts; i++) {
          await dbRepo.incrementEmbeddingAttempts(fileId);
        }
        await dbRepo.upsertFileEmbedding(fileId, List<double>.filled(2048, 0.5));

        final rows = await databaseManager.database!.select(
          'SELECT embedding_attempts FROM files WHERE id = ?',
          [fileId],
        );
        expect(rows.first['embedding_attempts'], 0);

        // Simulate the next pipeline revision invalidating stored vectors.
        await databaseManager.database!.execute(
          "UPDATE files_embeddings SET model_version = 'older-pipeline@1' "
          'WHERE file_id = ?',
          [fileId],
        );
        final missing = await dbRepo.getFilesWithMissingEmbeddings(limit: 50);
        expect(missing.any((f) => f.id == fileId), isTrue);
      });
    });

    test(
      'DatabaseRepository saveFileDescription writes description, tags, '
      'landmarks, and a description-type embedding alongside the file-type one',
      () async {
        final db = databaseManager.database!;
        final dbRepo = DatabaseRepository(db);
        final fileRepo = FileDesktopRepository(db);
        final colRepo = CollectionRepository(db);

        final colId = const Uuid().v4();
        await colRepo.addCollection(
          Collection(
            id: colId,
            name: 'Photos Collection',
            path: '/photos',
            type: 'file',
            scanner: 'local',
            needsReAuth: false,
            scanStatus: 'idle',
          ),
        );

        final fileId = const Uuid().v4();
        await fileRepo.create(
          File(
            id: fileId,
            name: 'eiffel.jpg',
            path: 'eiffel.jpg',
            parent: '/photos',
            dateCreated: DateTime.now(),
            dateLastModified: DateTime.now(),
            collectionId: colId,
            contentType: 'image/jpeg',
            size: 2048,
            isDeleted: false,
          ),
        );

        // Missing until both the description isolate's own eligibility
        // query and its file-embedding counterpart say so — the two run
        // independently and shouldn't affect one another.
        var missingDescriptions = await dbRepo.getFilesWithMissingDescriptions(
          limit: 10,
        );
        expect(missingDescriptions.any((f) => f.id == fileId), isTrue);

        // The file also has a 'file'-type image embedding already, as it
        // would once the embedding isolate reaches it first.
        final fileEmbedding = List<double>.filled(2048, 0.25);
        await dbRepo.upsertFileEmbedding(fileId, fileEmbedding);

        final descriptionEmbedding = List<double>.filled(2048, 0.75);
        await dbRepo.saveFileDescription(
          fileId,
          description: 'The Eiffel Tower at sunset with a clear sky.',
          tags: const ['sunset', 'landmark', 'sunset'], // dup tag on purpose
          landmarks: const ['Eiffel Tower'],
          embedding: descriptionEmbedding,
        );

        final fileRow = (await db.select(
          'SELECT description FROM files WHERE id = ?',
          [fileId],
        )).first;
        expect(
          fileRow['description'],
          'The Eiffel Tower at sunset with a clear sky.',
        );

        final tagRows = await db.select(
          'SELECT tag FROM file_tags WHERE file_id = ? ORDER BY tag',
          [fileId],
        );
        expect(
          tagRows.map((r) => r['tag']),
          ['landmark', 'sunset'],
          reason: 'duplicate tag is deduped by the (file_id, tag) key',
        );

        final landmarkRows = await db.select(
          'SELECT landmark FROM file_landmarks WHERE file_id = ?',
          [fileId],
        );
        expect(landmarkRows.map((r) => r['landmark']), ['Eiffel Tower']);

        // Both embedding types coexist for the same file, each independently
        // retrievable, and neither overwrote the other.
        final storedFileEmbedding = await dbRepo.getFileEmbedding(fileId);
        final storedDescriptionEmbedding = await dbRepo.getFileEmbedding(
          fileId,
          type: 'description',
        );
        expect(storedFileEmbedding, fileEmbedding);
        expect(storedDescriptionEmbedding, descriptionEmbedding);

        // Now that the description is set, it drops out of the eligibility
        // query — the isolate wouldn't reprocess it next pass.
        missingDescriptions = await dbRepo.getFilesWithMissingDescriptions(
          limit: 10,
        );
        expect(missingDescriptions.any((f) => f.id == fileId), isFalse);
      },
    );

    test(
      'DatabaseRepository getFileTags/getFileLandmarks return alphabetically, '
      'and delete removes exactly one entry',
      () async {
        final db = databaseManager.database!;
        final dbRepo = DatabaseRepository(db);
        final fileRepo = FileDesktopRepository(db);
        final colRepo = CollectionRepository(db);

        final colId = const Uuid().v4();
        await colRepo.addCollection(
          Collection(
            id: colId,
            name: 'Photos Collection',
            path: '/photos',
            type: 'file',
            scanner: 'local',
            needsReAuth: false,
            scanStatus: 'idle',
          ),
        );

        final fileId = const Uuid().v4();
        await fileRepo.create(
          File(
            id: fileId,
            name: 'eiffel.jpg',
            path: 'eiffel.jpg',
            parent: '/photos',
            dateCreated: DateTime.now(),
            dateLastModified: DateTime.now(),
            collectionId: colId,
            contentType: 'image/jpeg',
            size: 2048,
            isDeleted: false,
          ),
        );

        await dbRepo.saveFileDescription(
          fileId,
          description: 'The Eiffel Tower at sunset.',
          tags: const ['sunset', 'landmark'],
          landmarks: const ['Eiffel Tower'],
          embedding: List<double>.filled(2048, 0.5),
        );

        expect(await dbRepo.getFileTags(fileId), ['landmark', 'sunset']);
        expect(await dbRepo.getFileLandmarks(fileId), ['Eiffel Tower']);

        await dbRepo.deleteFileTag(fileId, 'landmark');
        expect(await dbRepo.getFileTags(fileId), ['sunset']);

        await dbRepo.deleteFileLandmark(fileId, 'Eiffel Tower');
        expect(await dbRepo.getFileLandmarks(fileId), isEmpty);

        // Deleting something already gone is a no-op, not an error.
        await dbRepo.deleteFileTag(fileId, 'landmark');
        expect(await dbRepo.getFileTags(fileId), ['sunset']);
      },
    );

    test('DatabaseRepository Email Embeddings Routing & Queries', () async {
      final db = databaseManager.database!;
      final dbRepo = DatabaseRepository(db);

      final colId = const Uuid().v4();
      final emailId = const Uuid().v4();

      // Insert dummy email record into database
      await db.execute(
        '''
        INSERT INTO emails (
          id, collection_id, date, "from", "to", cc, subject, plain_body, is_deleted
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
        ''',
        [
          emailId,
          colId,
          DateTime.now().millisecondsSinceEpoch,
          'sender@example.com',
          'recipient@example.com',
          'cc@example.com',
          'Test Email Subject',
          'Test email body text',
        ],
      );

      // Initially, the email has missing embeddings
      var missing = await dbRepo.getEmailsWithMissingEmbeddings(limit: 10);
      expect(missing.any((e) => e.id == emailId), isTrue);

      // Write the chunk embeddings
      final embedding = List<double>.filled(2048, 0.1);
      await dbRepo.replaceEmailEmbeddings(emailId, [embedding]);

      // Check database to ensure qwen3_vl_embedding is populated
      var rows = await db.select(
        'SELECT qwen3_vl_embedding FROM emails_embeddings WHERE email_id = ?',
        [emailId],
      );
      expect(rows, isNotEmpty);
      expect(rows.first['qwen3_vl_embedding'], isNotNull);

      // Now the embedding is present, so getEmailsWithMissingEmbeddings should NOT return it
      missing = await dbRepo.getEmailsWithMissingEmbeddings(limit: 10);
      expect(missing.any((e) => e.id == emailId), isFalse);

      // Get email embedding back
      final retrieved = await dbRepo.getEmailEmbeddings(emailId);
      expect(retrieved, hasLength(1));
      expect(retrieved.first.length, equals(2048));

      // Clean up/delete email embedding
      await dbRepo.deleteEmailEmbedding(emailId);
      rows = await db.select('SELECT * FROM emails_embeddings WHERE email_id = ?', [emailId]);
      expect(rows, isEmpty);
    });

    test('a long email is queued once, not once per chunk', () async {
      // The backfill query used to be an outer join, which emitted a copy of
      // an email for every embedding row it owned. Under chunking that turns a
      // batch of 100 into a handful of distinct emails re-embedded dozens of
      // times each, and the queue stops draining.
      final db = databaseManager.database!;
      final dbRepo = DatabaseRepository(db);
      final emailId = const Uuid().v4();

      await db.execute(
        '''
        INSERT INTO emails (
          id, collection_id, date, "from", "to", cc, subject, plain_body, is_deleted
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
        ''',
        [
          emailId,
          const Uuid().v4(),
          DateTime.now().millisecondsSinceEpoch,
          'sender@example.com',
          'recipient@example.com',
          '',
          'Long thread',
          'body',
        ],
      );

      // Five chunks, all stale: a model_version nothing recognises stands in
      // for the pre-chunking pipeline.
      for (var i = 0; i < 5; i++) {
        await db.execute(
          'INSERT INTO emails_embeddings '
          '(email_id, chunk_index, qwen3_vl_embedding, model_version) '
          'VALUES (?, ?, ?, ?)',
          [emailId, i, Uint8List(8192), 'older-pipeline@1'],
        );
      }

      final missing = await dbRepo.getEmailsWithMissingEmbeddings(limit: 100);
      expect(missing.where((e) => e.id == emailId), hasLength(1));
    });

    test('re-embedding a shortened email leaves no surplus chunks', () async {
      // A body can shrink — an edit, or a scanner replacing a truncated
      // snippet with the real text. Chunks 3..9 of the previous write are not
      // orphans (their `emails` row is very much alive), so nothing else in
      // the system would ever remove them, and every search would keep scoring
      // superseded text.
      final db = databaseManager.database!;
      final dbRepo = DatabaseRepository(db);
      final emailId = const Uuid().v4();

      await db.execute(
        '''
        INSERT INTO emails (
          id, collection_id, date, "from", "to", cc, subject, plain_body, is_deleted
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
        ''',
        [
          emailId,
          const Uuid().v4(),
          DateTime.now().millisecondsSinceEpoch,
          'sender@example.com',
          'recipient@example.com',
          '',
          'Shrinking',
          'body',
        ],
      );

      await dbRepo.replaceEmailEmbeddings(emailId, [
        for (var i = 0; i < 10; i++) List<double>.filled(2048, i / 10),
      ]);
      expect(await dbRepo.getEmailEmbeddings(emailId), hasLength(10));

      await dbRepo.replaceEmailEmbeddings(emailId, [
        for (var i = 0; i < 3; i++) List<double>.filled(2048, 0.5),
      ]);

      final rows = await db.select(
        'SELECT chunk_index FROM emails_embeddings WHERE email_id = ? '
        'ORDER BY chunk_index',
        [emailId],
      );
      expect(rows.map((r) => r['chunk_index']), [0, 1, 2]);
    });

    test('embedding queue skips images embedded in an email body', () async {
      // Every HTML newsletter carries a dozen spacers, logos and tracking
      // pixels as real image attachments. Embedding them costs on-device
      // inference time per image, buys nothing — they are only ever seen
      // inside the email they decorate — and pollutes similarity search.
      final db = databaseManager.database!;
      final dbRepo = DatabaseRepository(db);
      final colRepo = CollectionRepository(db);
      final fileRepo = FileDesktopRepository(db);

      final colId = const Uuid().v4();
      await colRepo.addCollection(
        Collection(
          id: colId,
          name: 'Mail',
          path: '/mail',
          type: 'email',
          scanner: 'gmail',
          needsReAuth: false,
          scanStatus: 'idle',
        ),
      );

      Future<String> addImage({required bool isInline, required String name}) async {
        final id = const Uuid().v4();
        await fileRepo.create(
          File(
            id: id,
            name: name,
            path: name,
            parent: '/mail',
            dateCreated: DateTime.now(),
            dateLastModified: DateTime.now(),
            collectionId: colId,
            contentType: 'application/image',
            size: 2048,
            isDeleted: false,
            isInline: isInline,
          ),
        );
        return id;
      }

      final photoId = await addImage(isInline: false, name: 'Sunset.jpg');
      final spacerId = await addImage(isInline: true, name: 'spacer.gif');

      final missing = await dbRepo.getFilesWithMissingEmbeddings(limit: 50);
      final ids = missing.map((f) => f.id);

      expect(ids, contains(photoId), reason: 'a real attachment still queues');
      expect(
        ids,
        isNot(contains(spacerId)),
        reason: 'an image the message body embeds must never be embedded',
      );
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

    test('AichatModelRepository OpenAI models description verification', () async {
      final db = databaseManager.database!;
      final repo = AichatModelRepository(db);

      // Fetch all models
      final models = await repo.getAll();
      final openaiModels = models.where((m) => m.group == 'openai').toList();

      expect(openaiModels.length, equals(4));

      final gpt55 = openaiModels.firstWhere((m) => m.alias == 'gpt-5.5');
      expect(gpt55.name, equals('GPT-5.5'));
      expect(gpt55.description, equals('A new class of intelligence for coding and professional work.'));

      final gpt54 = openaiModels.firstWhere((m) => m.alias == 'gpt-5.4');
      expect(gpt54.name, equals('GPT-5.4'));
      expect(gpt54.description, equals('A more affordable model for coding and professional work.'));

      final gptMini = openaiModels.firstWhere((m) => m.alias == 'gpt-5.4-mini');
      expect(gptMini.name, equals('GPT-5.4 mini'));
      expect(gptMini.description, equals('Our strongest mini model yet for coding, computer use, and subagents'));

      final gptImage = openaiModels.firstWhere((m) => m.alias == 'gpt-image-2');
      expect(gptImage.name, equals('GPT Image 2'));
      expect(gptImage.description, equals('State-of-the-art image generation model'));
    });

    test('AichatModelRepository Claude models description verification', () async {
      final db = databaseManager.database!;
      final repo = AichatModelRepository(db);

      // Fetch all models
      final models = await repo.getAll();
      final claudeModels = models.where((m) => m.group == 'claude').toList();

      expect(claudeModels.length, equals(4));

      final fabel5 = claudeModels.firstWhere((m) => m.alias == 'claude-fabel-5');
      expect(fabel5.name, equals('Fabel 5'));
      expect(fabel5.description, equals('Next-generation intelligence for long-running agents'));

      final opus48 = claudeModels.firstWhere((m) => m.alias == 'claude-opus-4-8');
      expect(opus48.name, equals('Opus 4.8'));
      expect(opus48.description, equals('For complex agentic coding and enterprise work'));

      final sonnet5 = claudeModels.firstWhere((m) => m.alias == 'claude-sonnet-5');
      expect(sonnet5.name, equals('Sonnet 5'));
      expect(sonnet5.description, equals('The best combination of speed and intelligence'));

      final haiku45 = claudeModels.firstWhere((m) => m.alias == 'claude-haiku-4-5');
      expect(haiku45.name, equals('Haiku 4.5'));
      expect(haiku45.description, equals('The fastest model with near-frontier intelligence'));
    });

    test('AichatModelRepository Grok models description verification', () async {
      final db = databaseManager.database!;
      final repo = AichatModelRepository(db);

      // Fetch all models
      final models = await repo.getAll();
      final grokModels = models.where((m) => m.group == 'grok').toList();

      expect(grokModels.length, equals(4));

      final grok43 = grokModels.firstWhere((m) => m.alias == 'grok-4.3');
      expect(grok43.name, equals('Grok 4.3'));
      expect(grok43.description, equals('For everything except code, audio, image, and video. The most intelligent and fastest model we’ve built.'));

      final grokImgGen = grokModels.firstWhere((m) => m.alias == 'grok-imagine-image-quality');
      expect(grokImgGen.name, equals('Imaging Generation'));
      expect(grokImgGen.description, equals('Generate images from text prompts with configurable aspect ratio, resolution, and count.'));

      final grokVideo = grokModels.firstWhere((m) => m.alias == 'grok-imagine-video-1.5');
      expect(grokVideo.name, equals('Image-to-Video'));
      expect(grokVideo.description, equals('Animate a still image with a text prompt. The source image becomes the first frame.'));

      final grokImgEdit = grokModels.firstWhere((m) => m.alias == 'grok-imagine-image-editing');
      expect(grokImgEdit.name, equals('Image Editing'));
      expect(grokImgEdit.description, equals('Edit images with natural language. Supports up to 3 reference images per request.'));
    });

    test('AichatModelRepository Gemini models description verification', () async {
      final db = databaseManager.database!;
      final repo = AichatModelRepository(db);

      // Fetch all models
      final models = await repo.getAll();
      final geminiModels = models.where((m) => m.group == 'gemini').toList();

      expect(geminiModels.length, equals(3));

      final gemini35 = geminiModels.firstWhere((m) => m.alias == 'gemini-3.5-flash');
      expect(gemini35.name, equals('Gemini 3.5 Flash'));
      expect(gemini35.description, equals('Frontier-level intelligence optimized for real-world tasks at a higher speed and lower cost.'));

      final gemini31 = geminiModels.firstWhere((m) => m.alias == 'gemini-3.1-pro-preview');
      expect(gemini31.name, equals('Gemini 3.1 Pro'));
      expect(gemini31.description, equals('Provides better thinking, improved token efficiency, and a more grounded, factually consistent experience.'));

      final geminiBanana = geminiModels.firstWhere((m) => m.alias == 'gemini-3.1-flash-image');
      expect(geminiBanana.name, equals('Nano Banana 2'));
      expect(geminiBanana.description, equals('Provides high-quality image generation and conversational editing'));
    });
  });
}
