import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// Two files in a real library could never be embedded — one a truncated JPEG,
/// one a `.jpg` whose bytes are not an image at all. Nothing recorded that, so
/// every pass re-selected them, re-read them, re-failed, and logged the same
/// parse error forever. These tests cover the counter that stops it, and the
/// distinction that keeps the counter from doing harm.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('embedding attempts', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late DatabaseRepository repo;
    late String collectionId;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mds_emb_attempts_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;
      repo = DatabaseRepository(db);

      collectionId = const Uuid().v4();
      await CollectionRepository(db).addCollection(
        Collection(
          id: collectionId,
          name: 'Photos',
          path: '/photos',
          type: 'file',
          scanner: 'local',
          needsReAuth: false,
          scanStatus: 'idle',
        ),
      );
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Future<String> addImage(String id) async {
      await FileDesktopRepository(db).create(
        File(
          id: id,
          name: '$id.jpg',
          path: '/photos/$id.jpg',
          parent: '/photos',
          dateCreated: DateTime(2026, 1, 1),
          dateLastModified: DateTime(2026, 1, 1),
          collectionId: collectionId,
          contentType: 'image/jpeg',
          size: 1024,
          isDeleted: false,
        ),
      );
      return id;
    }

    test('the column exists and starts at zero', () async {
      final columns = (await db.select('PRAGMA table_info(files)'))
          .map((r) => r['name'] as String)
          .toSet();
      expect(columns, contains('embedding_attempts'));

      await addImage('a');
      final rows = await db.select(
        'SELECT embedding_attempts FROM files WHERE id = ?',
        ['a'],
      );
      expect(rows.first['embedding_attempts'], 0);
    });

    test('an unembedded image is selected until its attempts run out',
        () async {
      await addImage('bad');

      expect(
        (await repo.getFilesWithMissingEmbeddings()).map((f) => f.id),
        contains('bad'),
      );

      // One short of the cap it is still worth trying.
      for (var i = 0; i < DatabaseRepository.maxEmbeddingAttempts - 1; i++) {
        await repo.incrementEmbeddingAttempts('bad');
      }
      expect(
        (await repo.getFilesWithMissingEmbeddings()).map((f) => f.id),
        contains('bad'),
      );

      // The one that reaches the cap drops it out for good, which is what stops
      // the endless identical parse errors.
      await repo.incrementEmbeddingAttempts('bad');
      expect(
        (await repo.getFilesWithMissingEmbeddings()).map((f) => f.id),
        isNot(contains('bad')),
      );
    });

    test('exhausting one file does not affect its neighbours', () async {
      await addImage('bad');
      await addImage('good');
      for (var i = 0; i < DatabaseRepository.maxEmbeddingAttempts; i++) {
        await repo.incrementEmbeddingAttempts('bad');
      }

      final selected =
          (await repo.getFilesWithMissingEmbeddings()).map((f) => f.id);
      expect(selected, contains('good'));
      expect(selected, isNot(contains('bad')));
    });

    test('a successful embedding takes the file out regardless of attempts',
        () async {
      await addImage('recovered');
      await repo.incrementEmbeddingAttempts('recovered');

      await repo.upsertFileEmbedding(
        'recovered',
        List<double>.filled(2048, 0.1),
      );

      expect(
        (await repo.getFilesWithMissingEmbeddings()).map((f) => f.id),
        isNot(contains('recovered')),
      );
    });
  });
}
