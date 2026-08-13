// Schema for document chunking — search plan §18e, Phase 7 step 2.
//
// Three things are pinned here, each because getting it wrong fails quietly
// rather than loudly: the widened `files_embeddings` key (a narrower one
// overwrites vectors instead of rejecting them), the migration's preservation
// of existing rows (losing `model_version` re-embeds thousands of valid
// images), and `file_chunks_fts` staying in step with its content table (a
// stale external-content index returns superseded text as a live hit).
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => '.');
  });

  /// A fresh database under a test-specific name, deleted first so a failed
  /// run cannot leave state that makes the next one pass.
  Future<AppDatabase> freshDb(String dbName) async {
    final supportDir = await getApplicationSupportDirectory();
    final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
    if (dbFile.existsSync()) dbFile.deleteSync();
    return AppDatabase.create(null, supportDir.path, dbName);
  }

  Future<void> insertFile(AppDatabase db, String id) async {
    await db.rawDb.execute(
      'INSERT INTO files (id, collection_id, name, path, parent, '
      'content_type, size) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [id, 'col-1', '$id.pdf', '/tmp/$id.pdf', '/tmp', 'application/pdf', 100],
    );
  }

  group('files_embeddings key', () {
    test('holds many chunk vectors for one file', () async {
      final db = await freshDb('chunk_key_test.db');
      await insertFile(db, 'f1');

      // The case a (file_id, type) key cannot represent: a 40-page PDF's
      // chunks all share type='chunk', so without `sequence` the second
      // insert would overwrite the first rather than adding a row.
      for (var i = 0; i < 3; i++) {
        await db.rawDb.execute(
          'INSERT INTO files_embeddings (file_id, type, sequence) '
          "VALUES ('f1', 'chunk', ?)",
          [i],
        );
      }
      final rows = await db.rawDb.select(
        "SELECT sequence FROM files_embeddings WHERE file_id = 'f1' "
        "AND type = 'chunk' ORDER BY sequence",
      );

      expect(rows.map((r) => r['sequence']), [0, 1, 2]);
      await db.close();
    });

    test('still separates a file vector from its description', () async {
      final db = await freshDb('chunk_key_types_test.db');
      await insertFile(db, 'f1');

      await db.rawDb.execute(
        "INSERT INTO files_embeddings (file_id, type) VALUES ('f1', 'file')",
      );
      await db.rawDb.execute(
        "INSERT INTO files_embeddings (file_id, type) "
        "VALUES ('f1', 'description')",
      );
      final rows = await db.rawDb.select(
        "SELECT type FROM files_embeddings WHERE file_id = 'f1' ORDER BY type",
      );

      expect(rows.map((r) => r['type']), ['description', 'file']);
      await db.close();
    });

    test('migrating from a (file_id, type) key keeps vectors and '
        'model_version', () async {
      final db = await freshDb('chunk_key_migration_test.db');

      // Rebuild the previous shape underneath, then reopen: this is what an
      // existing install looks like on the launch that introduces `sequence`.
      await db.rawDb.execute('DROP TABLE files_embeddings');
      await db.rawDb.execute('''
        CREATE TABLE files_embeddings (
          file_id TEXT NOT NULL,
          type TEXT NOT NULL DEFAULT 'file',
          qwen3_vl_embedding BLOB,
          model_version TEXT,
          PRIMARY KEY (file_id, type)
        )
      ''');
      await insertFile(db, 'f1');
      await db.rawDb.execute(
        'INSERT INTO files_embeddings (file_id, type, model_version) '
        "VALUES ('f1', 'file', 'qwen3-vl-2b-r1')",
      );
      final path = db.path!;
      final name = db.name!;
      await db.close();

      final reopened = await AppDatabase.create(null, path, name);
      final rows = await reopened.rawDb.select(
        'SELECT type, sequence, model_version FROM files_embeddings',
      );

      expect(rows.length, 1);
      expect(rows.first['sequence'], 0,
          reason: 'an image embedding is one-per-type, so 0 is correct');
      expect(
        rows.first['model_version'],
        'qwen3-vl-2b-r1',
        reason:
            'dropping model_version would present thousands of valid image '
            'vectors to the backfill queue as unfinished work',
      );
      await reopened.close();
    });
  });

  group('recovering PDFs retired by a missing pdfium', () {
    test('clears attempts on PDFs that never produced chunks', () async {
      final db = await freshDb('chunk_pdf_recovery_test.db');
      await insertFile(db, 'f1');
      // What the bug did: the server answered 422 for "no libpdfium", the
      // client counted it as unparseable content, and five passes retired a
      // perfectly good PDF permanently — embedding_attempts only resets on
      // success, and success was impossible until the library arrived.
      await db.rawDb.execute(
        "UPDATE files SET embedding_attempts = 5 WHERE id = 'f1'",
      );
      await db.rawDb.execute('PRAGMA user_version = 3');
      final path = db.path!;
      final name = db.name!;
      await db.close();

      final reopened = await AppDatabase.create(null, path, name);
      final rows = await reopened.rawDb.select(
        'SELECT embedding_attempts FROM files WHERE id = ?',
        ['f1'],
      );

      expect(rows.first['embedding_attempts'], 0);
      await reopened.close();
    });

    test('leaves a PDF that already extracted alone', () async {
      final db = await freshDb('chunk_pdf_recovery_done_test.db');
      await insertFile(db, 'f1');
      await db.rawDb.execute(
        "UPDATE files SET embedding_attempts = 2 WHERE id = 'f1'",
      );
      await db.rawDb.execute(
        'INSERT INTO file_chunks (file_id, chunk_index, text) '
        "VALUES ('f1', 0, 'already extracted')",
      );
      await db.rawDb.execute('PRAGMA user_version = 3');
      final path = db.path!;
      final name = db.name!;
      await db.close();

      final reopened = await AppDatabase.create(null, path, name);
      final rows = await reopened.rawDb.select(
        'SELECT embedding_attempts FROM files WHERE id = ?',
        ['f1'],
      );

      expect(rows.first['embedding_attempts'], 2,
          reason: 'this file was never blocked by the missing library');
      await reopened.close();
    });

    test('leaves genuinely unparseable .doc files retired', () async {
      final db = await freshDb('chunk_pdf_recovery_doc_test.db');
      await db.rawDb.execute(
        'INSERT INTO files (id, collection_id, name, path, parent, '
        'content_type, size, embedding_attempts) '
        "VALUES ('d1', 'col-1', 'broken.doc', '/tmp/broken.doc', '/tmp', "
        "'application/msword', 100, 5)",
      );
      await db.rawDb.execute('PRAGMA user_version = 3');
      final path = db.path!;
      final name = db.name!;
      await db.close();

      final reopened = await AppDatabase.create(null, path, name);
      final rows = await reopened.rawDb.select(
        'SELECT embedding_attempts FROM files WHERE id = ?',
        ['d1'],
      );

      expect(rows.first['embedding_attempts'], 5,
          reason:
              'docling cannot read these at all; un-retiring them would burn '
              'the budget again for nothing');
      await reopened.close();
    });
  });

  group('file_chunks_fts', () {
    test('indexes chunk text so a document is findable by its contents',
        () async {
      final db = await freshDb('chunk_fts_test.db');
      await insertFile(db, 'f1');
      await db.rawDb.execute(
        'INSERT INTO file_chunks (file_id, chunk_index, page, heading_path, '
        'text) VALUES (?, ?, ?, ?, ?)',
        ['f1', 0, 13, 'Speeches > 2019', 'my graduation speech draft'],
      );

      final rows = await db.rawDb.select(
        'SELECT c.file_id, c.page, c.heading_path FROM file_chunks_fts f '
        'JOIN file_chunks c ON c.rowid = f.rowid '
        'WHERE file_chunks_fts MATCH ?',
        ['graduation'],
      );

      expect(rows.length, 1);
      expect(rows.first['file_id'], 'f1');
      expect(rows.first['page'], 13, reason: 'the footnote target');
      expect(rows.first['heading_path'], 'Speeches > 2019');
      await db.close();
    });

    test('stops matching superseded text after a chunk set is replaced',
        () async {
      final db = await freshDb('chunk_fts_replace_test.db');
      await insertFile(db, 'f1');
      await db.rawDb.execute(
        'INSERT INTO file_chunks (file_id, chunk_index, text) VALUES (?, ?, ?)',
        ['f1', 0, 'obsolete draft wording'],
      );

      // What re-extraction does: delete the old set, insert the new one.
      await db.rawDb.execute("DELETE FROM file_chunks WHERE file_id = 'f1'");
      await db.rawDb.execute(
        'INSERT INTO file_chunks (file_id, chunk_index, text) VALUES (?, ?, ?)',
        ['f1', 0, 'revised final wording'],
      );

      expect(await _ftsCount(db, 'obsolete'), 0,
          reason: 'a stale term keeps a deleted chunk matchable forever');
      expect(await _ftsCount(db, 'revised'), 1);
      await db.close();
    });

    test('drops a deleted file\'s chunks and their index entries', () async {
      final db = await freshDb('chunk_fts_cascade_test.db');
      await insertFile(db, 'f1');
      await db.rawDb.execute(
        'INSERT INTO file_chunks (file_id, chunk_index, text) VALUES (?, ?, ?)',
        ['f1', 0, 'orphanable content'],
      );

      await db.rawDb.execute('PRAGMA foreign_keys = ON');
      await db.rawDb.execute("DELETE FROM files WHERE id = 'f1'");

      final remaining = await db.rawDb.select('SELECT * FROM file_chunks');
      expect(remaining, isEmpty, reason: 'ON DELETE CASCADE');
      expect(await _ftsCount(db, 'orphanable'), 0,
          reason: 'the cascade fires the delete trigger, retracting the terms');
      await db.close();
    });
  });
}

Future<int> _ftsCount(AppDatabase db, String match) async {
  final rows = await db.rawDb.select(
    'SELECT count(*) AS c FROM file_chunks_fts WHERE file_chunks_fts MATCH ?',
    [match],
  );
  return rows.first['c'] as int;
}
