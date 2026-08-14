// Chunk writes and the document backfill queue — search plan §18e/§18i.
//
// Both §16d traps are pinned here, because both fail by appearing to work:
// an outer-join queue that emits one copy of a file per chunk it already owns
// and so never drains, and an upserting write that leaves a shortened
// document's tail in place holding superseded text that nothing ever reaps.
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file_chunk.dart';
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
  late DatabaseRepository repo;

  Future<void> open(String dbName) async {
    final supportDir = await getApplicationSupportDirectory();
    final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
    if (dbFile.existsSync()) dbFile.deleteSync();
    db = await AppDatabase.create(null, supportDir.path, dbName);
    repo = DatabaseRepository(db);
    await db.rawDb.execute(
      "INSERT INTO collections (id, name, path, type, scanner, scan_status) "
      "VALUES ('col-1', 'Docs', '/tmp', 'files', 'local', 'idle')",
    );
  }

  Future<void> addFile(String id, {String ext = 'doc', int attempts = 0}) async {
    await db.rawDb.execute(
      'INSERT INTO files (id, collection_id, name, path, parent, '
      'content_type, size, embedding_attempts, date_created, '
      'date_last_modified) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [id, 'col-1', '$id.$ext', '/tmp/$id.$ext', '/tmp', 'application/msword',
        100, attempts, 0, 0],
    );
  }

  List<FileChunk> chunks(int n) => [
    for (var i = 0; i < n; i++)
      FileChunk(chunkIndex: i, text: 'chunk $i body', page: i + 1),
  ];

  List<List<double>> vectors(int n) => [
    for (var i = 0; i < n; i++) List<double>.filled(2048, 0.01 * (i + 1)),
  ];

  tearDown(() async => db.close());

  group('replaceFileChunks', () {
    test('stores text, provenance and vectors together', () async {
      await open('repo_chunks_write_test.db');
      await addFile('f1');

      await repo.replaceFileChunks('f1', chunks(3), embeddings: vectors(3));

      final stored = await db.rawDb.select(
        'SELECT chunk_index, page, text, model_version FROM file_chunks '
        'WHERE file_id = ? ORDER BY chunk_index',
        ['f1'],
      );
      expect(stored.length, 3);
      expect(stored.first['page'], 1);
      expect(stored.first['model_version'], EmbeddingModel.current);

      final vecs = await db.rawDb.select(
        "SELECT sequence FROM files_embeddings WHERE file_id = ? "
        "AND type = 'chunk' ORDER BY sequence",
        ['f1'],
      );
      expect(vecs.map((r) => r['sequence']), [0, 1, 2]);
    });

    test('a shortened re-extraction leaves no superseded tail', () async {
      await open('repo_chunks_shrink_test.db');
      await addFile('f1');
      await repo.replaceFileChunks('f1', chunks(10), embeddings: vectors(10));

      // The §16d trap: upserting would rewrite 0–2 and strand 3–9, which are
      // not orphans (the files row still exists) so nothing ever reaps them.
      await repo.replaceFileChunks('f1', chunks(3), embeddings: vectors(3));

      final stored = await db.rawDb.select(
        'SELECT chunk_index FROM file_chunks WHERE file_id = ?',
        ['f1'],
      );
      final vecs = await db.rawDb.select(
        "SELECT sequence FROM files_embeddings WHERE file_id = ? "
        "AND type = 'chunk'",
        ['f1'],
      );
      expect(stored.length, 3);
      expect(vecs.length, 3);
    });

    test('keeps text when there are no vectors, for the gated case', () async {
      await open('repo_chunks_gated_test.db');
      await addFile('f1');

      // §18a-2: too large to chunk, so extracted text lands with no vectors.
      await repo.replaceFileChunks('f1', [
        const FileChunk(chunkIndex: 0, text: 'enormous spreadsheet contents'),
      ]);

      final stored = await db.rawDb.select(
        'SELECT text FROM file_chunks WHERE file_id = ?',
        ['f1'],
      );
      final vecs = await db.rawDb.select(
        "SELECT * FROM files_embeddings WHERE file_id = ? AND type = 'chunk'",
        ['f1'],
      );
      expect(stored.length, 1, reason: 'still findable by keyword');
      expect(vecs, isEmpty, reason: 'deliberately not embedded');
    });

    test('does not leave stale vectors when a re-run is gated', () async {
      await open('repo_chunks_regate_test.db');
      await addFile('f1');
      await repo.replaceFileChunks('f1', chunks(4), embeddings: vectors(4));

      await repo.replaceFileChunks('f1', [
        const FileChunk(chunkIndex: 0, text: 'now too large to chunk'),
      ]);

      final vecs = await db.rawDb.select(
        "SELECT * FROM files_embeddings WHERE file_id = ? AND type = 'chunk'",
        ['f1'],
      );
      expect(vecs, isEmpty,
          reason: 'vectors from the previous run would outlive their chunks');
    });

    test('refuses more vectors than chunks', () async {
      await open('repo_chunks_mismatch_test.db');
      await addFile('f1');

      expect(
        () => repo.replaceFileChunks('f1', chunks(2), embeddings: vectors(3)),
        throwsArgumentError,
        reason: 'a vector with no chunk row is a hit that cannot be rendered',
      );
    });

    test('leaves a file vector and description untouched', () async {
      await open('repo_chunks_types_test.db');
      await addFile('f1');
      await db.rawDb.execute(
        "INSERT INTO files_embeddings (file_id, type) VALUES ('f1', 'file')",
      );
      await db.rawDb.execute(
        "INSERT INTO files_embeddings (file_id, type) "
        "VALUES ('f1', 'description')",
      );

      await repo.replaceFileChunks('f1', chunks(2), embeddings: vectors(2));
      await repo.replaceFileChunks('f1', chunks(1), embeddings: vectors(1));

      final other = await db.rawDb.select(
        "SELECT type FROM files_embeddings WHERE file_id = ? "
        "AND type <> 'chunk' ORDER BY type",
        ['f1'],
      );
      expect(other.map((r) => r['type']), ['description', 'file'],
          reason: 'the delete must be scoped to type = chunk');
    });
  });

  group('getFilesWithMissingChunks', () {
    test('offers an unprocessed document once, not once per chunk', () async {
      await open('repo_queue_dupes_test.db');
      await addFile('f1');
      await addFile('f2');
      await repo.replaceFileChunks('f2', chunks(8), embeddings: vectors(8));

      final queued = await repo.getFilesWithMissingChunks(limit: 50);

      expect(queued.map((f) => f.id).toList(), ['f1'],
          reason: 'an outer join would emit f2 eight times and never drain');
    });

    test('does not re-offer a document that was gated', () async {
      await open('repo_queue_gated_test.db');
      await addFile('f1');
      await repo.replaceFileChunks('f1', [
        const FileChunk(chunkIndex: 0, text: 'too large to chunk'),
      ]);

      final queued = await repo.getFilesWithMissingChunks(limit: 50);

      expect(queued, isEmpty,
          reason:
              'asking the vector table would answer "unprocessed" forever and '
              're-extract this file on every pass');
    });

    test('re-offers a document chunked by a superseded model', () async {
      await open('repo_queue_stale_test.db');
      await addFile('f1');
      await repo.replaceFileChunks('f1', chunks(2), embeddings: vectors(2));
      await db.rawDb.execute(
        "UPDATE file_chunks SET model_version = 'ancient' WHERE file_id = 'f1'",
      );

      final queued = await repo.getFilesWithMissingChunks(limit: 50);

      expect(queued.map((f) => f.id).toList(), ['f1'],
          reason: 'a model upgrade must re-chunk without a separate migration');
    });

    test('skips images, and files retired after repeated failures', () async {
      await open('repo_queue_filters_test.db');
      await addFile('doc1');
      await addFile('photo', ext: 'jpg');
      await addFile('broken', attempts: DatabaseRepository.maxEmbeddingAttempts);

      final queued = await repo.getFilesWithMissingChunks(limit: 50);

      expect(queued.map((f) => f.id).toList(), ['doc1']);
    });

    Future<void> addWorkspaceFile(String id, String name, String kind) async {
      await db.rawDb.execute(
        'INSERT INTO files (id, collection_id, name, path, parent, '
        'content_type, size, date_created, date_last_modified) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [id, 'col-1', name, 'gdrive://$id', '/',
          'application/vnd.google-apps.$kind', 100, 0, 0],
      );
    }

    test('offers Workspace documents by content type, not by name', () async {
      await open('repo_queue_workspace_test.db');
      // Named like markdown and not markdown. The queue cannot sniff content
      // the way the extractor does, so content_type is the only signal
      // available before a read — and these are fetched by export (§18k).
      await addWorkspaceFile('gdoc', 'Plan.md', 'document');
      await addWorkspaceFile('gsheet', 'Expenses / Receipts', 'spreadsheet');

      final queued = await repo.getFilesWithMissingChunks(limit: 50);

      expect(queued.map((f) => f.id).toSet(), {'gdoc', 'gsheet'},
          reason: 'the spreadsheet has no extension at all, so an '
              'extension-only filter would never reach it');
    });

    test('skips Workspace types that are not documents', () async {
      await open('repo_queue_workspace_other_test.db');
      await addWorkspaceFile('form', 'Signup Form', 'form');
      await addWorkspaceFile('draw', 'Architecture', 'drawing');
      await addWorkspaceFile('gdoc', 'Notes', 'document');

      final queued = await repo.getFilesWithMissingChunks(limit: 50);

      expect(queued.map((f) => f.id).toList(), ['gdoc'],
          reason: 'a Form has no document export to ask for');
    });

    test('skips formats excluded by policy and by measurement', () async {
      await open('repo_queue_excluded_test.db');
      await addFile('page', ext: 'html');
      await addFile('deck', ext: 'ppt');
      await addFile('memo', ext: 'rtf');

      final queued = await repo.getFilesWithMissingChunks(limit: 50);

      expect(queued.map((f) => f.id).toList(), ['memo'],
          reason: 'html duplicates its own email; ppt yields slide titles only');
    });
  });
}
