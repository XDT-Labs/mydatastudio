// A cloud file edited at the provider must not keep its old archive copy or
// its old index entries.
//
// The sync only sees metadata: a new modified time, size or content hash. The
// local copy under `<storage>/files/<scheme>/...` and the embedding, chunks and
// description built from it all still describe the old bytes. Unless the
// upsert drops them, the downloader treats the file as already archived and
// every indexing queue treats it as done — so search answers from content the
// file no longer has, forever.
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/file_chunk.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/embedding_model.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => '.');
  });

  late AppDatabase db;
  late FileDesktopRepository files;
  late DatabaseRepository index;

  setUp(() async {
    final supportDir = await getApplicationSupportDirectory();
    const dbName = 'cloud_content_change_test.db';
    final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
    if (dbFile.existsSync()) dbFile.deleteSync();
    db = await AppDatabase.create(null, supportDir.path, dbName);
    files = FileDesktopRepository(db);
    index = DatabaseRepository(db);
    await db.rawDb.execute(
      "INSERT INTO collections (id, name, path, type, scanner, scan_status) "
      "VALUES ('c1', 'My Drive', 'root', 'files', 'cloud.drive', 'idle')",
    );
  });

  tearDown(() async => db.close());

  File doc({
    String id = 'c1:doc',
    String name = 'report.pdf',
    String contentType = 'application/pdf',
    DateTime? modified,
    int size = 100,
    String? hash,
  }) => File(
    id: id,
    collectionId: 'c1',
    name: name,
    path: 'fake://${id.split(':').last}',
    parent: '',
    dateCreated: DateTime.utc(2024),
    dateLastModified: modified ?? DateTime.utc(2024),
    lastScannedDate: DateTime.utc(2024),
    isDeleted: false,
    size: size,
    contentType: contentType,
    contentHash: hash,
  );

  List<double> vector() => List<double>.filled(EmbeddingModel.dimension, 0.01);

  /// Stores [f] as a fully archived and indexed file: local copy recorded,
  /// file embedding, chunks and a description all present.
  Future<void> archiveAndIndex(File f) async {
    await files.upsertAll([f]);
    await db.execute(
      'UPDATE files SET local_path = ?, embedding_attempts = 2, '
      'description_attempts = 3 WHERE id = ?',
      ['/archive/${f.name}', f.id],
    );
    await index.upsertFileEmbedding(f.id, vector());
    await index.replaceFileChunks(
      f.id,
      [const FileChunk(chunkIndex: 0, text: 'old text')],
      embeddings: [vector()],
    );
    await index.saveFileDescription(
      f.id,
      description: 'old description',
      tags: const [],
      landmarks: const [],
      embedding: vector(),
    );
  }

  Future<Map<String, Object?>> row(String id) async =>
      (await db.select(
        'SELECT local_path, description, embedding_attempts, description_attempts '
        'FROM files WHERE id = ?',
        [id],
      )).single;

  Future<int> count(String table, String id) async =>
      (await db.select('SELECT COUNT(*) AS n FROM $table WHERE file_id = ?', [
            id,
          ])).single['n']
          as int;

  Future<bool> queuedForChunks(String id) async =>
      (await index.getFilesWithMissingChunks(limit: 50)).any((f) => f.id == id);
  Future<bool> queuedForDescription(String id) async => (await index
      .getFilesWithMissingDescriptions(limit: 50)).any((f) => f.id == id);

  group('upsertAll(replaceChangedContent: true)', () {
    test(
      'a new modified time drops the local copy and re-queues indexing',
      () async {
        await archiveAndIndex(doc());
        expect(await queuedForChunks('c1:doc'), isFalse);
        expect(await queuedForDescription('c1:doc'), isFalse);

        await files.upsertAll([
          doc(modified: DateTime.utc(2025)),
        ], replaceChangedContent: true);

        final r = await row('c1:doc');
        expect(
          r['local_path'],
          isNull,
          reason: 'the old copy must be replaced',
        );
        expect(r['description'], isNull);
        expect(r['embedding_attempts'], 0);
        expect(r['description_attempts'], 0);
        expect(await count('files_embeddings', 'c1:doc'), 0);
        expect(await count('file_chunks', 'c1:doc'), 0);
        expect(await queuedForChunks('c1:doc'), isTrue);
        expect(await queuedForDescription('c1:doc'), isTrue);
      },
    );

    test('a changed image is re-queued for its file embedding', () async {
      final photo = doc(
        id: 'c1:pic',
        name: 'pic.jpg',
        contentType: 'image/jpeg',
        size: 10,
      );
      await archiveAndIndex(photo);
      bool queued(List<File> l) => l.any((f) => f.id == 'c1:pic');
      expect(
        queued(await index.getFilesWithMissingEmbeddings(limit: 50)),
        isFalse,
      );

      await files.upsertAll([
        doc(id: 'c1:pic', name: 'pic.jpg', contentType: 'image/jpeg', size: 11),
      ], replaceChangedContent: true);

      expect(
        queued(await index.getFilesWithMissingEmbeddings(limit: 50)),
        isTrue,
      );
      expect((await row('c1:pic'))['local_path'], isNull);
    });

    test('a different content hash counts as a change', () async {
      await archiveAndIndex(doc(hash: 'aaa'));
      await files.upsertAll([doc(hash: 'bbb')], replaceChangedContent: true);
      expect((await row('c1:doc'))['local_path'], isNull);
      expect(await queuedForChunks('c1:doc'), isTrue);
    });

    test('an unchanged file keeps its copy and its index', () async {
      await archiveAndIndex(doc(hash: 'aaa'));
      await files.upsertAll([doc(hash: 'aaa')], replaceChangedContent: true);

      final r = await row('c1:doc');
      expect(r['local_path'], '/archive/report.pdf');
      expect(r['description'], 'old description');
      expect(await count('file_chunks', 'c1:doc'), 1);
      expect(await count('files_embeddings', 'c1:doc'), greaterThan(0));
    });

    test(
      'equal hashes win over a new modified time (rename, metadata edit)',
      () async {
        // Drive bumps modifiedTime on a rename; the bytes, and so everything
        // derived from them, are still good.
        await archiveAndIndex(doc(hash: 'aaa'));
        await files.upsertAll([
          doc(hash: 'aaa', modified: DateTime.utc(2025)),
        ], replaceChangedContent: true);
        expect((await row('c1:doc'))['local_path'], '/archive/report.pdf');
        expect(await count('file_chunks', 'c1:doc'), 1);
      },
    );

    test('a first sighting is a plain insert', () async {
      await files.upsertAll([doc()], replaceChangedContent: true);
      expect(await queuedForChunks('c1:doc'), isTrue);
    });
  });

  test('plain upsertAll leaves local_path and the index alone', () async {
    // Other scanners own local_path differently (sync-folder archiver, mail
    // attachments); the invalidation is opt-in.
    await archiveAndIndex(doc());
    await files.upsertAll([doc(modified: DateTime.utc(2025))]);
    expect((await row('c1:doc'))['local_path'], '/archive/report.pdf');
    expect(await count('file_chunks', 'c1:doc'), 1);
  });
}
