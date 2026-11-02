import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
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

  Future<AppDatabase> freshDb(String dbName) async {
    final supportDir = await getApplicationSupportDirectory();
    final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
    if (dbFile.existsSync()) dbFile.deleteSync();
    for (final suffix in const ['-wal', '-shm']) {
      final sideFile = io.File('${dbFile.path}$suffix');
      if (sideFile.existsSync()) sideFile.deleteSync();
    }
    return AppDatabase.create(null, supportDir.path, dbName);
  }

  test('switches to EmbeddingGemma 2 when user_version < 6', () async {
    const dbName = 'migration_to_gemma2_test.db';
    final db = await freshDb(dbName);
    final path = db.path!;
    final name = db.name!;

    // 1. Insert parent collections, files, emails
    await db.rawDb.execute(
      "INSERT OR REPLACE INTO collections (id, name, path, type, scanner, scan_status) "
      "VALUES ('col1', 'col1', '/tmp', 'files', 'file.local', 'idle')",
    );
    await db.rawDb.execute(
      "INSERT INTO files (id, collection_id, name, path, parent, content_type, size, is_deleted, embedding_attempts) "
      "VALUES ('f1', 'col1', 'photo.jpg', '/tmp/photo.jpg', '/tmp', 'image/jpeg', 100, 0, 3)",
    );
    await db.rawDb.execute(
      'INSERT INTO emails (id, collection_id, date, "from", "to", subject, plain_body, is_deleted) '
      "VALUES ('e1', 'col1', 1000, 'from@x.com', 'to@x.com', 'subject', 'body', 0)",
    );

    // 2. Populate legacy rows in files_embeddings and emails_embeddings with non-null qwen3_vl_embedding
    final legacyVector = Uint8List(2048 * 4);
    legacyVector[0] = 42;
    await db.rawDb.execute(
      "INSERT INTO files_embeddings (file_id, type, sequence, qwen3_vl_embedding, model_version) "
      "VALUES ('f1', 'file', 0, ?, 'Qwen/Qwen3-VL-Embedding-2B@2')",
      [legacyVector],
    );
    await db.rawDb.execute(
      "INSERT INTO emails_embeddings (email_id, chunk_index, qwen3_vl_embedding, model_version) "
      "VALUES ('e1', 0, ?, 'Qwen/Qwen3-VL-Embedding-2B@2')",
      [legacyVector],
    );

    // 3. Create photo_cluster_runs with node and member
    const runId = 'test-run-1';
    await db.rawDb.execute(
      "INSERT INTO photo_cluster_runs (id, collection_scope, created_at, photo_count, max_groups, seed, status) "
      "VALUES (?, 'all', 1000, 1, 4, 42, 'ready')",
      [runId],
    );
    await db.rawDb.execute(
      "INSERT INTO photo_cluster_nodes (run_id, node_id, member_count, coherence, centroid, label_status) "
      "VALUES (?, 0, 1, 0.9, ?, 'ready')",
      [runId, legacyVector],
    );
    await db.rawDb.execute(
      "INSERT INTO photo_cluster_members (run_id, node_id, file_id) "
      "VALUES (?, 0, 'f1')",
      [runId],
    );

    // 4. Insert legacy aichat_models row
    await db.rawDb.execute(
      "DELETE FROM aichat_models WHERE alias = 'embeddinggemma-2'",
    );
    await db.rawDb.execute(
      "INSERT INTO aichat_models (id, alias, \"group\", name, type, enabled, created_at, updated_at) "
      "VALUES ('legacy-model', 'qwen3-vl-embedding:2b', 'embedding', 'Qwen 3 VL Embedding 2B', 'transformers', 0, 1000, 1000)",
    );

    // 5. Force user_version = 5 to simulate pre-migration state
    await db.rawDb.execute('PRAGMA user_version = 5');
    await db.close();

    // Reopen database - triggers initSchema and _switchToEmbeddingGemma2
    final reopened = await AppDatabase.create(null, path, name);

    // Assert user_version = 6
    final versionRows = await reopened.rawDb.select('PRAGMA user_version');
    final version = versionRows.first.values.first as int;
    expect(version, 6);

    // Assert embeddinggemma2_embedding column exists on both tables
    final feColumns = (await reopened.rawDb.select('PRAGMA table_info(files_embeddings)'))
        .map((r) => r['name'] as String)
        .toSet();
    expect(feColumns, contains('embeddinggemma2_embedding'));

    final eeColumns = (await reopened.rawDb.select('PRAGMA table_info(emails_embeddings)'))
        .map((r) => r['name'] as String)
        .toSet();
    expect(eeColumns, contains('embeddinggemma2_embedding'));

    // Assert qwen3_vl_embedding is NULL everywhere
    final feRows = await reopened.rawDb.select('SELECT qwen3_vl_embedding FROM files_embeddings');
    expect(feRows.every((r) => r['qwen3_vl_embedding'] == null), isTrue);

    final eeRows = await reopened.rawDb.select('SELECT qwen3_vl_embedding FROM emails_embeddings');
    expect(eeRows.every((r) => r['qwen3_vl_embedding'] == null), isTrue);

    // Assert embedding_attempts = 0
    final fileRows = await reopened.rawDb.select('SELECT embedding_attempts FROM files WHERE id = ?', ['f1']);
    expect(fileRows.first['embedding_attempts'], 0);

    // Assert photo_cluster_runs and nodes/members are empty
    final runs = await reopened.rawDb.select('SELECT * FROM photo_cluster_runs');
    expect(runs, isEmpty);
    final nodes = await reopened.rawDb.select('SELECT * FROM photo_cluster_nodes');
    expect(nodes, isEmpty);
    final members = await reopened.rawDb.select('SELECT * FROM photo_cluster_members');
    expect(members, isEmpty);

    // Assert no qwen3-vl-embedding:2b and embeddinggemma-2 exists
    final oldModel = await reopened.rawDb.select(
      "SELECT * FROM aichat_models WHERE alias = 'qwen3-vl-embedding:2b'",
    );
    expect(oldModel, isEmpty);

    final newModel = await reopened.rawDb.select(
      "SELECT * FROM aichat_models WHERE alias = 'embeddinggemma-2'",
    );
    expect(newModel, isNotEmpty);
    expect(newModel.first['hf_repo'], EmbeddingModel.modelName);

    await reopened.close();
  });

  test('migration is a no-op when user_version is already 6', () async {
    const dbName = 'migration_noop_when_v6_test.db';
    final db = await freshDb(dbName);
    final path = db.path!;
    final name = db.name!;

    // Initial creation already set user_version = 6
    final versionRows = await db.rawDb.select('PRAGMA user_version');
    expect(versionRows.first.values.first as int, 6);

    // Insert parent collection and file
    await db.rawDb.execute(
      "INSERT OR REPLACE INTO collections (id, name, path, type, scanner, scan_status) "
      "VALUES ('col1', 'col1', '/tmp', 'files', 'file.local', 'idle')",
    );
    await db.rawDb.execute(
      "INSERT INTO files (id, collection_id, name, path, parent, content_type, size, is_deleted, embedding_attempts) "
      "VALUES ('f1', 'col1', 'photo.jpg', '/tmp/photo.jpg', '/tmp', 'image/jpeg', 100, 0, 5)",
    );

    // Manually write into qwen3_vl_embedding post-migration
    final testBlob = Uint8List.fromList([1, 2, 3, 4]);
    await db.rawDb.execute(
      "INSERT INTO files_embeddings (file_id, type, sequence, qwen3_vl_embedding, model_version) "
      "VALUES ('f1', 'file', 0, ?, 'test@1')",
      [testBlob],
    );

    await db.close();

    // Reopening database should skip _switchToEmbeddingGemma2 because user_version is 6
    final reopened = await AppDatabase.create(null, path, name);

    // Assert qwen3_vl_embedding survived re-open
    final feRows = await reopened.rawDb.select(
      "SELECT qwen3_vl_embedding FROM files_embeddings WHERE file_id = 'f1'",
    );
    expect(feRows.first['qwen3_vl_embedding'], isNotNull);

    // Assert embedding_attempts remained 5
    final fileRows = await reopened.rawDb.select(
      "SELECT embedding_attempts FROM files WHERE id = 'f1'",
    );
    expect(fileRows.first['embedding_attempts'], 5);

    await reopened.close();
  });
}
