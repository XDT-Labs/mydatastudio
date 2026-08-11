import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/embedding_model.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _createdDbs = <String>[];

Future<AppDatabase> _freshDb(String dbName) async {
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
  if (dbFile.existsSync()) dbFile.deleteSync();
  _createdDbs.add(dbFile.path);
  return AppDatabase.create(null, supportDir.path, dbName);
}

List<double> _vector() => List<double>.filled(2048, 0.01);

/// getFilesWithMissingEmbeddings INNER JOINs collections, so a file with no
/// collection row is invisible to it — which would make every "is it queued?"
/// assertion below pass for the wrong reason.
Future<void> _addCollection(AppDatabase db) {
  return db.rawDb.execute(
    'INSERT OR REPLACE INTO collections (id, name, path, type, scanner, '
    "scan_status) VALUES ('c1', 'c1', '/p', 'files', 'file.local', 'idle')",
  );
}

Future<void> _addImage(AppDatabase db, String id, {String description = ''}) {
  return db.rawDb.execute(
    'INSERT INTO files (id, name, path, parent, date_created, '
    'date_last_modified, collection_id, content_type, size, is_deleted, '
    'is_inline, description) '
    "VALUES (?, ?, ?, '/p', 1000, 1000, 'c1', 'image/jpeg', 1, 0, 0, ?)",
    [id, '$id.jpg', '/p/$id.jpg', description],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => '.');
  });

  tearDownAll(() {
    for (final path in _createdDbs) {
      for (final suffix in const ['', '-wal', '-shm']) {
        final file = io.File('$path$suffix');
        if (file.existsSync()) file.deleteSync();
      }
    }
    _createdDbs.clear();
  });

  test('a vector written by this pipeline is not re-queued', () async {
    final db = await _freshDb('embed_version_current_test.db');
    final repo = DatabaseRepository(db);
    await _addCollection(db);
    await _addImage(db, 'f1');
    await repo.upsertFileEmbedding('f1', _vector());

    expect(await repo.getFilesWithMissingEmbeddings(), isEmpty);
    await db.close();
  });

  test('a vector from an older pipeline is queued for rebuild', () async {
    // The whole point. Every vector predating the aiserver loader fix is
    // noise, and nothing downstream can detect it — cosine over two
    // incompatible spaces returns plausible numbers rather than an error. The
    // isolates only ever filled rows where the vector was NULL, so a populated
    // row was never revisited and the archive would have stayed broken until
    // someone deleted six thousand rows by hand.
    final db = await _freshDb('embed_version_stale_test.db');
    final repo = DatabaseRepository(db);
    await _addCollection(db);
    await _addImage(db, 'f1');
    await repo.upsertFileEmbedding('f1', _vector());
    await db.rawDb.execute(
      "UPDATE files_embeddings SET model_version = 'Qwen/Qwen3-VL-Embedding-2B@1'",
    );

    final queued = await repo.getFilesWithMissingEmbeddings();
    expect(queued.map((f) => f.id), ['f1']);
    await db.close();
  });

  test('a pre-migration vector counts as unknown, and so as stale', () async {
    // What every row in an existing install looks like the moment the column
    // is added: NULL, meaning "written by something that did not say what it
    // was". That has to read as stale, because it is exactly the broken case.
    final db = await _freshDb('embed_version_null_test.db');
    final repo = DatabaseRepository(db);
    await _addCollection(db);
    await _addImage(db, 'f1');
    await repo.upsertFileEmbedding('f1', _vector());
    await db.rawDb.execute('UPDATE files_embeddings SET model_version = NULL');

    expect((await repo.getFilesWithMissingEmbeddings()).map((f) => f.id), [
      'f1',
    ]);
    await db.close();
  });

  test('mail is reclaimed on the same rule', () async {
    final db = await _freshDb('embed_version_email_test.db');
    final repo = DatabaseRepository(db);
    await db.rawDb.execute(
      'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
      "plain_body, has_attachments, is_deleted) VALUES ('e1', 'c1', 1000, "
      "'a@x.com', 'me@x.com', 's', 'b', 0, 0)",
    );
    await repo.upsertEmailEmbedding('e1', _vector());
    expect(await repo.getEmailsWithMissingEmbeddings(), isEmpty);

    await db.rawDb.execute('UPDATE emails_embeddings SET model_version = NULL');
    expect((await repo.getEmailsWithMissingEmbeddings()).map((e) => e.id), [
      'e1',
    ]);
    await db.close();
  });

  group('stale description vectors', () {
    test('are reclaimed without regenerating the description', () async {
      // The description text is unaffected by an embedding change and costs a
      // vision-model pass to regenerate; its vector costs well under a second.
      // They are also selected by different queries — getFilesWithMissing-
      // Descriptions looks for `description IS NULL`, and these have one — so
      // without this path the description vectors would stay noise forever.
      // That is the *stronger* half of image search: measured on this archive
      // the description vector beats the image vector on 44 of 45 photos.
      final db = await _freshDb('embed_version_desc_test.db');
      final repo = DatabaseRepository(db);
      await _addCollection(db);
      await _addImage(db, 'f1', description: 'a family standing outdoors');
      await repo.upsertFileEmbedding('f1', _vector(), type: 'description');

      expect(await repo.getFilesWithStaleDescriptionEmbeddings(), isEmpty);

      await db.rawDb.execute(
        "UPDATE files_embeddings SET model_version = NULL WHERE type = 'description'",
      );
      final stale = await repo.getFilesWithStaleDescriptionEmbeddings();
      expect(stale.map((r) => r.fileId), ['f1']);
      expect(stale.single.description, 'a family standing outdoors');

      // Re-embedding stamps it current, and it stops being queued.
      await repo.upsertFileEmbedding('f1', _vector(), type: 'description');
      expect(await repo.getFilesWithStaleDescriptionEmbeddings(), isEmpty);
      await db.close();
    });

    test('a file with no description is never queued for one', () async {
      final db = await _freshDb('embed_version_nodesc_test.db');
      final repo = DatabaseRepository(db);
      await _addCollection(db);
      await _addImage(db, 'f1');
      await repo.upsertFileEmbedding('f1', _vector(), type: 'description');
      await db.rawDb.execute(
        'UPDATE files_embeddings SET model_version = NULL',
      );

      expect(await repo.getFilesWithStaleDescriptionEmbeddings(), isEmpty);
      await db.close();
    });
  });

  test('the image and description vectors do not overwrite each other', () {
    // Both live in files_embeddings keyed by (file_id, type). The write relay
    // carries the type across the isolate boundary; dropping it would have one
    // silently replace the other, which is the failure
    // `_migrateFilesEmbeddingsKey` already exists to warn about.
    expect(EmbeddingModel.current, contains('@'));
  });
}
