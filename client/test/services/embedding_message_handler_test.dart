// The write relay's document case — search plan §18j.
//
// The two existing message shapes carry vectors only. A document carries
// metadata *and* vectors, across two tables, and they have to land together:
// a vector whose chunk row is missing is a search hit that cannot render a
// footnote, and chunk text whose vector is missing is merely un-embedded.
// Only the second of those is acceptable, so the relay is where the asymmetry
// is enforced.
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/embedding_message_handler.dart';
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
  final logger = AppLogger(null);

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
    await db.rawDb.execute(
      'INSERT INTO files (id, collection_id, name, path, parent, '
      'content_type, size, date_created, date_last_modified) '
      "VALUES ('f1', 'col-1', 'report.doc', '/tmp/report.doc', '/tmp', "
      "'application/msword', 100, 0, 0)",
    );
  }

  tearDown(() async => db.close());

  Map<String, Object?> chunkMap(int index, String text, {int? page}) => {
    'chunk_index': index,
    'text': text,
    'page': page,
    'heading_path': 'Report > Findings',
    'char_start': index * 100,
    'char_end': (index + 1) * 100,
  };

  test('stores chunk text and vectors from one message', () async {
    await open('relay_chunks_test.db');

    await handleEmbeddingMessage(repo, {
      'table': 'file_chunks',
      'id': 'f1',
      'chunks': [chunkMap(0, 'first passage', page: 4), chunkMap(1, 'second')],
      'embeddings': [
        List<double>.filled(2048, 0.1),
        List<double>.filled(2048, 0.2),
      ],
    }, logger);

    final chunks = await db.rawDb.select(
      'SELECT chunk_index, page, heading_path, char_start, text '
      'FROM file_chunks WHERE file_id = ? ORDER BY chunk_index',
      ['f1'],
    );
    expect(chunks.length, 2);
    expect(chunks.first['page'], 4);
    expect(chunks.first['heading_path'], 'Report > Findings');
    expect(chunks.first['char_start'], 0);

    final vectors = await db.rawDb.select(
      "SELECT sequence FROM files_embeddings WHERE file_id = ? "
      "AND type = 'chunk'",
      ['f1'],
    );
    expect(vectors.length, 2);
  });

  test('stores text when the message carries no vectors at all', () async {
    await open('relay_chunks_gated_test.db');

    // The gated case (§18a-2) and the missing-embedding-model case look
    // identical here, and both must keep the document keyword-searchable.
    await handleEmbeddingMessage(repo, {
      'table': 'file_chunks',
      'id': 'f1',
      'chunks': [chunkMap(0, 'enormous spreadsheet')],
    }, logger);

    final chunks = await db.rawDb.select(
      'SELECT text FROM file_chunks WHERE file_id = ?',
      ['f1'],
    );
    expect(chunks.length, 1);
  });

  test('stores a partial vector run as a prefix of the chunks', () async {
    await open('relay_chunks_partial_test.db');

    // The isolate stops embedding at the first failure, so the vector list is
    // a prefix. The text still lands whole; the tail is embedded on a later
    // pass rather than leaving the document unsearchable in the meantime.
    await handleEmbeddingMessage(repo, {
      'table': 'file_chunks',
      'id': 'f1',
      'chunks': [chunkMap(0, 'a'), chunkMap(1, 'b'), chunkMap(2, 'c')],
      'embeddings': [List<double>.filled(2048, 0.1)],
    }, logger);

    final chunks = await db.rawDb.select(
      'SELECT chunk_index FROM file_chunks WHERE file_id = ?',
      ['f1'],
    );
    final vectors = await db.rawDb.select(
      "SELECT sequence FROM files_embeddings WHERE file_id = ? "
      "AND type = 'chunk'",
      ['f1'],
    );
    expect(chunks.length, 3);
    expect(vectors.map((r) => r['sequence']), [0]);
  });

  test('an unknown table is logged, not thrown', () async {
    await open('relay_unknown_test.db');

    // A relay that throws takes down the write queue behind it, so an
    // unrecognised message has to be inert.
    await expectLater(
      handleEmbeddingMessage(
        repo,
        {'table': 'nonsense', 'id': 'f1'},
        logger,
      ),
      completes,
    );
  });
}
