import 'dart:io' as io;
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/embedding_model.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mydatastudio/custom_path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseManager', () {
    io.Directory? tempDir;

    setUpAll(() async {
      // Mock path_provider
      const MethodChannel channel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            return ".";
          });

      tempDir = await getTemporaryDirectory();
    });

    tearDownAll(() {
      if (tempDir != null && tempDir!.existsSync()) {
        // tempDir!.deleteSync(recursive: true);
      }
    });

    test('instance should not be null', () {
      expect(DatabaseManager.instance, isNotNull);
    });

    test(
      'isDatabaseConfigured should return false if config file does not exist',
      () async {
        // Ensure no config file exists
        final supportPath = await getApplicationSupportDirectory();
        final configFile = io.File(p.join(supportPath.path, 'config.json'));
        if (configFile.existsSync()) {
          configFile.deleteSync();
        }

        expect(await DatabaseManager.instance.isDatabaseConfigured(), isFalse);
      },
    );

    test(
      'isDatabaseConfigured should return true if config file exists',
      () async {
        final supportPath = await getApplicationSupportDirectory();
        final configFile = io.File(p.join(supportPath.path, 'config.json'));

        // Create dummy config file
        configFile.createSync(recursive: true);
        configFile.writeAsStringSync(jsonEncode({'path': tempDir!.path}));

        expect(await DatabaseManager.instance.isDatabaseConfigured(), isTrue);

        // Cleanup
        configFile.deleteSync();
      },
    );

    test('initializeDatabase should setup database and repository', () async {
      final supportPath = await getApplicationSupportDirectory();
      final configFile = io.File(p.join(supportPath.path, 'config.json'));

      // Create dummy config file
      configFile.createSync(recursive: true);
      configFile.writeAsStringSync(jsonEncode({'path': tempDir!.path}));

      await DatabaseManager.instance.initializeDatabase();

      expect(DatabaseManager.instance.database, isNotNull);
      expect(DatabaseManager.instance.repository, isNotNull);
      expect(DatabaseManager.isInitializedNotifier.value, isTrue);

      // Cleanup
      configFile.deleteSync();
      DatabaseManager.instance.dispose();
    });

    test(
      'initializeDatabase should setup database and repository with split storage and database config keys',
      () async {
        DatabaseManager.isTesting = false;
        final supportPath = await getApplicationSupportDirectory();
        final expectedDatabasePath = supportPath.path;
        final configFile = io.File(p.join(supportPath.path, 'config.json'));

        // Create dummy config file with split keys
        configFile.createSync(recursive: true);
        configFile.writeAsStringSync(
          jsonEncode({
            'storage': tempDir!.path,
            'database': expectedDatabasePath,
          }),
        );

        await DatabaseManager.instance.initializeDatabase();

        expect(DatabaseManager.instance.storagePath, equals(tempDir!.path));
        expect(
          DatabaseManager.instance.databaseDirectoryPath,
          equals(expectedDatabasePath),
        );
        expect(DatabaseManager.instance.database, isNotNull);
        expect(DatabaseManager.instance.repository, isNotNull);
        expect(DatabaseManager.isInitializedNotifier.value, isTrue);

        // Cleanup
        DatabaseManager.isTesting = true;
        configFile.deleteSync();
        DatabaseManager.instance.dispose();
      },
    );

    test(
      'initializeDatabase should throw FileSystemException if storage directory is inaccessible',
      () async {
        DatabaseManager.isTesting = false;
        final supportPath = await getApplicationSupportDirectory();
        final configFile = io.File(p.join(supportPath.path, 'config.json'));

        // Use a storage path that cannot be accessed or created
        const inaccessiblePath = '/non_existent_volume_xyz_123/storage_dir';

        configFile.createSync(recursive: true);
        configFile.writeAsStringSync(jsonEncode({'storage': inaccessiblePath}));

        expect(
          () => DatabaseManager.instance.initializeDatabase(),
          throwsA(isA<io.FileSystemException>()),
        );

        // Cleanup
        DatabaseManager.isTesting = true;
        configFile.deleteSync();
        DatabaseManager.instance.dispose();
      },
    );

    test(
      'testPathSupportsWal should return true for local temporary path',
      () async {
        final testPath = p.join(tempDir!.path, 'wal_test_dir');
        final supports = await DatabaseManager.testPathSupportsWal(testPath);
        expect(supports, isTrue);

        // Clean up test dir
        final dir = io.Directory(testPath);
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      },
    );

    test(
      'AppDatabase.create should redirect to application support directory if path does not support WAL',
      () async {
        // We pass a non-existent invalid path which will cause testPathSupportsWal to return false
        const nonWalPath = '/invalid_path_non_existent';
        final appDb = await AppDatabase.create(
          null,
          nonWalPath,
          'redirect_test.db',
        );

        // It should have redirected to application support directory (which is local and supports WAL)
        final supportDir = await getApplicationSupportDirectory();
        expect(appDb.path, equals(supportDir.path));

        // Clean up the test database file
        await appDb.close();
        final dbFile = io.File(
          p.join(supportDir.path, 'data', 'redirect_test.db'),
        );
        if (dbFile.existsSync()) {
          dbFile.deleteSync();
        }
      },
    );

    test(
      'AppDatabase.create adds files.content_id to a database created before it existed',
      () async {
        // The DDL only runs for a brand-new database, so a column added later
        // reaches existing installs solely through the guarded ALTER. If that
        // stops working, every attachment write fails at runtime — on an
        // upgraded install only, which is exactly where it would go unnoticed.
        final supportDir = await getApplicationSupportDirectory();
        const dbName = 'content_id_migration_test.db';
        final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
        if (dbFile.existsSync()) dbFile.deleteSync();

        var appDb = await AppDatabase.create(null, supportDir.path, dbName);
        // Drop back to the pre-migration shape.
        await appDb.rawDb.execute('ALTER TABLE files DROP COLUMN content_id');
        expect(await _fileColumns(appDb), isNot(contains('content_id')));
        await appDb.close();

        // Reopening is what an upgraded install does.
        appDb = await AppDatabase.create(null, supportDir.path, dbName);
        expect(await _fileColumns(appDb), contains('content_id'));

        // And again — the ALTER must not fire a second time and throw.
        await appDb.close();
        appDb = await AppDatabase.create(null, supportDir.path, dbName);
        expect(await _fileColumns(appDb), contains('content_id'));

        await appDb.close();
        if (dbFile.existsSync()) dbFile.deleteSync();
      },
    );

    test('adding files.is_inline backfills already-imported mail', () async {
      // Without the backfill, is_inline would only ever be right for mail
      // scanned after the upgrade, and every archive already on disk would
      // keep pouring spacer GIFs and ad banners into the photos module until
      // the user deleted and re-imported it.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'is_inline_backfill_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);
      // Back to the pre-migration shape, so reopening runs the migration. The
      // index goes first and is not incidental: an archive old enough to lack
      // `is_inline` also predates the photo-timeline index over it, and SQLite
      // refuses to drop a column an index still names.
      await appDb.rawDb.execute('DROP INDEX IF EXISTS idx_files_active_date');
      await appDb.rawDb.execute('ALTER TABLE files DROP COLUMN is_inline');

      await appDb.rawDb.execute(
        "INSERT INTO emails (id, collection_id, date, [from], [to], subject, "
        "html_body, is_read, has_attachments, is_deleted) "
        "VALUES ('e1', 'c1', 0, 'a@b', 'c@d', 'Newsletter', ?, 0, 1, 0)",
        ['<html><img src="cid:logo@corp"><img src="cid:banner.gif"></html>'],
      );
      // A plain-text message: nothing it carries can be embedded.
      await appDb.rawDb.execute(
        "INSERT INTO emails (id, collection_id, date, [from], [to], subject, "
        "html_body, is_read, has_attachments, is_deleted) "
        "VALUES ('e2', 'c1', 0, 'a@b', 'c@d', 'Holiday', '', 0, 1, 0)",
      );

      Future<void> addFile(
        String id,
        String name,
        String? contentId,
        String emailId,
      ) async {
        await appDb.rawDb.execute(
          "INSERT INTO files (id, name, path, parent, date_created, "
          "date_last_modified, collection_id, content_type, size, "
          "is_deleted, email_id, content_id) "
          "VALUES (?, ?, ?, '/tmp', 0, 0, 'c1', 'application/image', 1, 0, ?, ?)",
          [id, name, '/tmp/$name', emailId, contentId],
        );
      }

      // Matched by content id.
      await addFile('f1', 'logo.png', 'logo@corp', 'e1');
      // Matched by filename — how mail with no content id writes the ref.
      await addFile('f2', 'banner.gif', null, 'e1');
      // Attached to the newsletter but not referenced by it: a real photo.
      await addFile('f3', 'Sunset.jpg', null, 'e1');
      // Same filename as an embedded one, but on a plain-text message.
      await addFile('f4', 'logo.png', null, 'e2');

      // A stale embedding for one of the images about to be flagged.
      await appDb.rawDb.execute(
        "INSERT INTO files_embeddings (file_id) VALUES ('f1')",
      );
      await appDb.rawDb.execute(
        "INSERT INTO files_embeddings (file_id) VALUES ('f3')",
      );
      await appDb.close();

      // Reopening is what an upgraded install does.
      appDb = await AppDatabase.create(null, supportDir.path, dbName);

      Future<int> inlineFlag(String id) async {
        final rows = await appDb.rawDb.select(
          'SELECT is_inline FROM files WHERE id = ?',
          [id],
        );
        return rows.first['is_inline'] as int;
      }

      expect(await inlineFlag('f1'), 1, reason: 'referenced by content id');
      expect(await inlineFlag('f2'), 1, reason: 'referenced by filename');
      expect(await inlineFlag('f3'), 0, reason: 'a real attachment');
      expect(
        await inlineFlag('f4'),
        0,
        reason: 'a plain-text message embeds nothing',
      );

      // Embeddings for flagged images are dropped; the real photo keeps its.
      final remaining = await appDb.rawDb.select(
        'SELECT file_id FROM files_embeddings ORDER BY file_id',
      );
      expect(remaining.map((r) => r['file_id']), ['f3']);

      // And the index is back. It was declared only in schemaDDL, which runs
      // just once when the database is created — so every archive that
      // predates it never got it, and the photo timeline paged by full-scanning
      // `files`. Verified against a real upgraded install: `files` carried
      // every other index and not this one. The assertion belongs here because
      // this fixture *is* an upgraded install; on a fresh one it cannot fail.
      final indexes = await appDb.rawDb.select(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = 'files'",
      );
      expect(
        indexes.map((r) => r['name']),
        contains('idx_files_active_date'),
        reason: 'an index only a fresh install has is an index most users '
            'do not have',
      );

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('an archive carrying duplicate indexes sheds them on open', () async {
      // `idx_files_geo` and `files_latlng_idx` were the same index over the
      // same two columns of `files`, and `idx_file_tags_tag` the same as
      // `file_tags_tag_idx`. Both pairs existed together on a real install.
      // A duplicate index is not merely untidy: the planner can only use one,
      // so the other is a second B-tree written on every insert into the two
      // tables the scanners write to most, for no read anyone can benefit from.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'duplicate_index_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);
      // Put the legacy names back, which is the shape every existing archive
      // is in — they were created once and nothing has ever removed them.
      await appDb.rawDb.execute(
        'CREATE INDEX IF NOT EXISTS idx_files_geo ON files (latitude, longitude);',
      );
      await appDb.rawDb.execute(
        'CREATE INDEX IF NOT EXISTS idx_file_tags_tag ON file_tags (tag);',
      );
      await appDb.close();

      appDb = await AppDatabase.create(null, supportDir.path, dbName);

      Future<List<String>> indexesOn(String table) async {
        final rows = await appDb.rawDb.select(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = ? AND name NOT LIKE 'sqlite_autoindex%' "
          "ORDER BY name",
          [table],
        );
        return rows.map((r) => r['name'] as String).toList();
      }

      expect(
        await indexesOn('files'),
        isNot(contains('idx_files_geo')),
        reason: 'the duplicate is dropped, not just no longer created — an '
            'archive that already has it never runs the create again',
      );
      expect(
        await indexesOn('files'),
        contains('files_latlng_idx'),
        reason: 'the surviving name still covers the bounding-box query',
      );
      expect(await indexesOn('file_tags'), ['file_tags_tag_idx']);

      // Idempotent: the second open has nothing left to drop and must not
      // throw on the missing index.
      await appDb.close();
      appDb = await AppDatabase.create(null, supportDir.path, dbName);
      expect(await indexesOn('file_tags'), ['file_tags_tag_idx']);

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    Future<void> expectMetadataSchemaMigrated(
      AppDatabase appDb,
      String dbFile,
    ) async {
      final embeddingRows = await appDb.rawDb.select(
        'SELECT type FROM files_embeddings WHERE file_id = ?',
        ['f1'],
      );
      expect(
        embeddingRows.first['type'],
        'file',
        reason:
            'pre-existing embeddings are all file-level; the rebuild '
            'backfills them without a separate UPDATE pass',
      );

      // A second embedding type for the same file is now representable —
      // the whole point of moving off a file_id-only primary key.
      await appDb.rawDb.execute(
        "INSERT INTO files_embeddings (file_id, type) VALUES ('f1', 'description')",
      );
      final bothRows = await appDb.rawDb.select(
        'SELECT type FROM files_embeddings WHERE file_id = ? ORDER BY type',
        ['f1'],
      );
      expect(bothRows.map((r) => r['type']), ['description', 'file']);

      final fileColumns =
          (await appDb.rawDb.select(
            'PRAGMA table_info(files)',
          )).map((r) => r['name'] as String).toSet();
      expect(fileColumns.contains('description'), true);

      // Join tables exist and are queryable/indexable by value.
      await appDb.rawDb.execute(
        "INSERT INTO file_tags (file_id, tag) VALUES ('f1', 'beach')",
      );
      final tagRows = await appDb.rawDb.select(
        'SELECT file_id FROM file_tags WHERE tag = ?',
        ['beach'],
      );
      expect(tagRows.map((r) => r['file_id']), ['f1']);

      await appDb.rawDb.execute(
        "INSERT INTO file_landmarks (file_id, landmark) "
        "VALUES ('f1', 'Golden Gate Bridge')",
      );
      final landmarkRows = await appDb.rawDb.select(
        'SELECT file_id FROM file_landmarks WHERE landmark = ?',
        ['Golden Gate Bridge'],
      );
      expect(landmarkRows.map((r) => r['file_id']), ['f1']);

      await appDb.close();
      final f = io.File(dbFile);
      if (f.existsSync()) f.deleteSync();
    }

    test('reopening a database with the original files_embeddings shape '
        '(file_id-only key) migrates it to (file_id, type)', () async {
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'metadata_migration_original_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);
      await appDb.rawDb.execute('DROP TABLE files_embeddings');
      await appDb.rawDb.execute('''
          CREATE TABLE files_embeddings (
            file_id TEXT PRIMARY KEY,
            qwen3_vl_embedding BLOB,
            FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
          )
        ''');
      // A database old enough to predate files.description also predates
      // files_fts, which indexes that column. Dropping the column while the
      // triggers are live is a state no real install can reach — the
      // indexes are created after the column is added — so drop them too
      // rather than testing against a shape that cannot occur.
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS files_fts_ai');
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS files_fts_au');
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS files_fts_ad');
      await appDb.rawDb.execute('DROP TABLE IF EXISTS files_fts');
      await appDb.rawDb.execute('ALTER TABLE files DROP COLUMN description');
      await appDb.rawDb.execute('DROP TABLE file_tags');
      await appDb.rawDb.execute('DROP TABLE file_landmarks');
      await appDb.rawDb.execute(
        "INSERT INTO files (id, name, path, parent, date_created, "
        "date_last_modified, collection_id, content_type, size, is_deleted) "
        "VALUES ('f1', 'sunset.jpg', '/tmp/sunset.jpg', '/tmp', 0, 0, 'c1', "
        "'image/jpeg', 1, 0)",
      );
      await appDb.rawDb.execute(
        "INSERT INTO files_embeddings (file_id) VALUES ('f1')",
      );
      await appDb.close();

      // Reopening is what an upgraded install does.
      appDb = await AppDatabase.create(null, supportDir.path, dbName);
      await expectMetadataSchemaMigrated(appDb, dbFile.path);
    });

    test(
      'reopening a database with the intermediate shape (type column '
      'present but not part of the key) migrates it to (file_id, type)',
      () async {
        // This is the exact shape an install upgraded through the version
        // that added `type` via ALTER TABLE ADD COLUMN, before the key
        // itself was widened, would already be sitting on.
        final supportDir = await getApplicationSupportDirectory();
        const dbName = 'metadata_migration_intermediate_test.db';
        final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
        if (dbFile.existsSync()) dbFile.deleteSync();

        var appDb = await AppDatabase.create(null, supportDir.path, dbName);
        await appDb.rawDb.execute('DROP TABLE files_embeddings');
        await appDb.rawDb.execute('''
          CREATE TABLE files_embeddings (
            file_id TEXT PRIMARY KEY,
            qwen3_vl_embedding BLOB,
            type TEXT NOT NULL DEFAULT 'file'
          )
        ''');
        // A database old enough to predate files.description also predates
        // files_fts, which indexes that column. Dropping the column while the
        // triggers are live is a state no real install can reach — the
        // indexes are created after the column is added — so drop them too
        // rather than testing against a shape that cannot occur.
        await appDb.rawDb.execute('DROP TRIGGER IF EXISTS files_fts_ai');
        await appDb.rawDb.execute('DROP TRIGGER IF EXISTS files_fts_au');
        await appDb.rawDb.execute('DROP TRIGGER IF EXISTS files_fts_ad');
        await appDb.rawDb.execute('DROP TABLE IF EXISTS files_fts');
        await appDb.rawDb.execute('ALTER TABLE files DROP COLUMN description');
        await appDb.rawDb.execute('DROP TABLE file_tags');
        await appDb.rawDb.execute('DROP TABLE file_landmarks');
        await appDb.rawDb.execute(
          "INSERT INTO files (id, name, path, parent, date_created, "
          "date_last_modified, collection_id, content_type, size, is_deleted) "
          "VALUES ('f1', 'sunset.jpg', '/tmp/sunset.jpg', '/tmp', 0, 0, 'c1', "
          "'image/jpeg', 1, 0)",
        );
        await appDb.rawDb.execute(
          "INSERT INTO files_embeddings (file_id, type) VALUES ('f1', 'file')",
        );
        await appDb.close();

        appDb = await AppDatabase.create(null, supportDir.path, dbName);
        await expectMetadataSchemaMigrated(appDb, dbFile.path);
      },
    );

    test(
      'getRealApplicationSupportPath should return correct path even if PathProviderPlatform is overridden',
      () async {
        final originalSupportDir = await getApplicationSupportDirectory();
        final realPath = await DatabaseManager.getRealApplicationSupportPath();
        expect(realPath, equals(originalSupportDir.path));

        // Mock override CustomPathProviderPlatform
        final oldPlatform = PathProviderPlatform.instance;
        PathProviderPlatform.instance = CustomPathProviderPlatform(
          oldPlatform,
          '/some_custom_overridden_path',
        );

        final overridenSupportDir = await getApplicationSupportDirectory();
        expect(
          overridenSupportDir.path,
          equals('/some_custom_overridden_path'),
        );

        // getRealApplicationSupportPath should still return original
        final realPathAfterOverride =
            await DatabaseManager.getRealApplicationSupportPath();
        expect(realPathAfterOverride, equals(originalSupportDir.path));

        // Restore platform
        PathProviderPlatform.instance = oldPlatform;
      },
    );

    test('emails_fts triggers track insert, update and delete', () async {
      // Sync is by SQL trigger rather than from Dart precisely so no write
      // path can skip it: six scanners reach `emails` through the write
      // relay, and a Dart-side index call is the thing a seventh forgets.
      // If these triggers stop firing, mail stays in the database but
      // silently vanishes from keyword search — visible in the UI, absent
      // from results, with nothing logged.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'fts_trigger_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      final appDb = await AppDatabase.create(null, supportDir.path, dbName);

      await _insertEmail(appDb, id: 'e1', subject: 'Quarterly report');
      expect(await _ftsMatches(appDb, 'quarterly'), 1);

      // An external-content update must retract the OLD terms; passing the
      // new values to the 'delete' command would leave 'quarterly' indexed
      // against a row that no longer says it.
      await appDb.rawDb.execute(
        "UPDATE emails SET subject = 'Annual report' WHERE id = 'e1'",
      );
      expect(await _ftsMatches(appDb, 'quarterly'), 0);
      expect(await _ftsMatches(appDb, 'annual'), 1);

      await appDb.rawDb.execute("DELETE FROM emails WHERE id = 'e1'");
      expect(await _ftsMatches(appDb, 'annual'), 0);

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('search indexes backfill mail that predates them', () async {
      // The triggers only see writes made after they exist. Without the
      // one-time rebuild, every message already in an upgraded archive is
      // invisible to keyword search forever — the failure looks like
      // "search is broken for old mail only", which is the hardest kind to
      // notice in testing and the most common in the field.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'fts_backfill_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);

      // Reproduce a pre-index archive: rows present, triggers and index
      // gone, and the migration marked as not-yet-run.
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS emails_fts_ai');
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS emails_fts_au');
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS emails_fts_ad');
      await _insertEmail(appDb, id: 'old-1', subject: 'Graduation speech');
      expect(await _ftsMatches(appDb, 'graduation'), 0);
      await appDb.rawDb.execute('PRAGMA user_version = 1');
      await appDb.close();

      // Reopening is what an upgraded install does.
      appDb = await AppDatabase.create(null, supportDir.path, dbName);
      expect(await _ftsMatches(appDb, 'graduation'), 1);

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('legacy .doc files retired by a partial reader are re-offered', () async {
      // §18m: docling reported 87 of this archive's 229 .doc files as damaged
      // when the files were fine — their OLE2 directories list the very stream
      // the error said was missing. A textutil fallback now reads 85 of them,
      // but `embedding_attempts` only resets on success, so without this pass
      // the fix would reach almost nothing it was built for: the files that
      // motivated it are precisely the ones already sitting at the cap.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'doc_unretire_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);
      Future<void> insert(String id, String name, int attempts) =>
          appDb.rawDb.execute(
            'INSERT INTO files (id, name, path, parent, date_created, '
            'date_last_modified, collection_id, content_type, size, '
            'is_deleted, embedding_attempts) '
            "VALUES (?, ?, ?, '/tmp', 0, 0, 'c1', 'application/msword', 1, 0, ?)",
            [id, name, '/tmp/$name', attempts],
          );

      await insert('retired', 'nondisclsr.doc', 5);
      await insert('chunked', 'readable.doc', 5);
      await insert('other', 'sheet.xls', 5);
      // A .doc that already produced text was never the reader's victim, so
      // re-offering it would spend a fresh budget re-deriving what is on disk.
      await appDb.rawDb.execute(
        "INSERT INTO file_chunks (file_id, chunk_index, text) "
        "VALUES ('chunked', 0, 'already extracted')",
      );
      await appDb.rawDb.execute('PRAGMA user_version = 4');
      await appDb.close();

      // Reopening is what an upgraded install does.
      appDb = await AppDatabase.create(null, supportDir.path, dbName);
      Future<int> attemptsOf(String id) async {
        final rows = await appDb.rawDb.select(
          'SELECT embedding_attempts FROM files WHERE id = ?',
          [id],
        );
        return rows.first.values.first as int;
      }

      expect(await attemptsOf('retired'), 0);
      expect(await attemptsOf('chunked'), 5);
      // The fallback only covers .doc; nothing else may have its budget spent
      // again on the strength of a fix that cannot reach it.
      expect(await attemptsOf('other'), 5);

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('renaming contacts to emails_contacts keeps the indexed rows', () async {
      // The rename runs before _createSearchIndexes for a reason: that method
      // creates emails_contacts with IF NOT EXISTS, so an install still holding
      // the old table would otherwise end up with both — a populated one nothing
      // reads and an empty one everything reads. The visible symptom would be
      // `from:` autocomplete and prose person-resolution silently returning
      // nothing on exactly the archives that have the most mail in them.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'contacts_rename_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);

      // Reproduce an install carrying the pre-rename shape.
      await appDb.rawDb.execute('DROP TABLE IF EXISTS emails_contacts');
      await appDb.rawDb.execute('''
        CREATE TABLE contacts (
          address        TEXT PRIMARY KEY,
          display_name   TEXT,
          local_part     TEXT NOT NULL,
          message_count  INTEGER NOT NULL DEFAULT 0,
          sent_count     INTEGER NOT NULL DEFAULT 0,
          first_seen     INTEGER,
          last_seen      INTEGER
        );
      ''');
      await appDb.rawDb.execute(
        'CREATE INDEX contacts_name_idx ON contacts (display_name)',
      );
      await appDb.rawDb.execute(
        'INSERT INTO contacts (address, display_name, local_part, '
        'message_count) VALUES (?, ?, ?, ?)',
        ['mnimer@allaire.com', 'Mike Nimer', 'mnimer', 6889],
      );
      await appDb.close();

      // Reopening is what an upgraded install does.
      appDb = await AppDatabase.create(null, supportDir.path, dbName);

      final rows = await appDb.rawDb.select(
        'SELECT address, message_count FROM emails_contacts',
      );
      expect(rows.length, 1);
      expect(rows.first['address'], 'mnimer@allaire.com');
      // Carried across, not rebuilt: a rebuild would re-derive this from an
      // emails table that is empty here, and 6889 would come back as nothing.
      expect(rows.first['message_count'], 6889);

      final old = await appDb.rawDb.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='contacts'",
      );
      expect(old, isEmpty, reason: 'the old table must not survive the rename');

      // The old index names must go with it, or a future contacts module
      // creating its own contacts_name_idx collides with a leftover.
      final staleIndex = await appDb.rawDb.select(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND name='contacts_name_idx'",
      );
      expect(staleIndex, isEmpty);

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('email embeddings rekey to chunks, discarding whole-body vectors', () async {
      // Chunking supersedes the stored vectors, and they cannot simply be
      // carried across as chunk 0: they would keep the current model_version,
      // which is the only signal getEmailsWithMissingEmbeddings has. Every
      // long email in the archive would look finished and keep its diluted
      // single vector forever — the failure chunking exists to fix, made
      // invisible. Dropping them is what re-enqueues the archive.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'email_chunk_rekey_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);

      // Reproduce a pre-chunking install: one row per email, keyed by email_id
      // alone, stamped with the pipeline that is still current.
      await appDb.rawDb.execute('DROP TABLE emails_embeddings');
      await appDb.rawDb.execute('''
        CREATE TABLE emails_embeddings (
          email_id TEXT PRIMARY KEY,
          qwen3_vl_embedding BLOB,
          model_version TEXT,
          FOREIGN KEY (email_id) REFERENCES emails(id) ON DELETE CASCADE
        );
      ''');
      await appDb.rawDb.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
        'plain_body, is_deleted) VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
        ['e1', 'c1', 1000, 'a@x.com', 'me@x.com', 'Subject', 'body'],
      );
      await appDb.rawDb.execute(
        'INSERT INTO emails_embeddings (email_id, qwen3_vl_embedding, '
        'model_version) VALUES (?, ?, ?)',
        ['e1', Uint8List(8192), EmbeddingModel.current],
      );
      await appDb.close();

      // Reopening is what an upgraded install does.
      appDb = await AppDatabase.create(null, supportDir.path, dbName);

      final info = await appDb.rawDb.select(
        'PRAGMA table_info(emails_embeddings)',
      );
      final chunkColumn = info.firstWhere((r) => r['name'] == 'chunk_index');
      expect(
        chunkColumn['pk'],
        greaterThan(0),
        reason: 'chunk_index must be part of the key, or two chunks of one '
            'email overwrite each other instead of coexisting',
      );

      final rows = await appDb.rawDb.select('SELECT * FROM emails_embeddings');
      expect(rows, isEmpty, reason: 'whole-body vectors must not survive');

      // The point of discarding them: the email is queued again.
      final missing = await DatabaseRepository(
        appDb,
      ).getEmailsWithMissingEmbeddings();
      expect(missing.map((e) => e.id), ['e1']);

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('HTML-only mail becomes searchable on upgrade', () async {
      // A third of a real archive (425 of 1,279 measured here) arrives with
      // an html_body and no plain_body. The first version of the index read
      // plain_body only, so every word of those messages was unsearchable —
      // and silently so: the query worked, it just never matched them.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'body_text_backfill_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);

      // Reproduce a pre-body_text archive: the column and index shape are
      // gone, and the row carries only HTML.
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS emails_fts_ai');
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS emails_fts_au');
      await appDb.rawDb.execute('DROP TRIGGER IF EXISTS emails_fts_ad');
      await appDb.rawDb.execute('DROP TABLE IF EXISTS emails_fts');
      await appDb.rawDb.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
        'html_body) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          'html-1',
          'c1',
          0,
          'a@x.com',
          'me@x.com',
          'newsletter',
          '<html><style>.hdr{color:red}</style><body>'
              '<p>Our <b>ColdFusion</b> migration notes</p></body></html>',
        ],
      );
      await appDb.rawDb.execute('ALTER TABLE emails DROP COLUMN body_text');
      await appDb.rawDb.execute('PRAGMA user_version = 2');
      await appDb.close();

      // Reopening is what an upgraded install does.
      appDb = await AppDatabase.create(null, supportDir.path, dbName);

      expect(await _ftsMatches(appDb, 'coldfusion'), 1);
      // Markup never reaches the index — otherwise a CSS class name would be
      // a searchable word across every HTML message in the archive.
      expect(await _ftsMatches(appDb, 'hdr'), 0);
      expect(await _ftsMatches(appDb, 'style'), 0);

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test(
      'plain text is preferred over the HTML body when both exist',
      () async {
        // Extraction can only ever approximate what the sender wrote, so it is
        // a fallback rather than a replacement.
        final supportDir = await getApplicationSupportDirectory();
        const dbName = 'body_text_prefers_plain_test.db';
        final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
        if (dbFile.existsSync()) dbFile.deleteSync();

        final appDb = await AppDatabase.create(null, supportDir.path, dbName);
        await appDb.rawDb.execute(
          'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
          'plain_body, html_body) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [
            'both-1',
            'c1',
            0,
            'a@x.com',
            'me@x.com',
            's',
            'plainmarker',
            '<p>htmlmarker</p>',
          ],
        );
        await appDb.rawDb.execute('PRAGMA user_version = 2');
        await appDb.close();

        final reopened = await AppDatabase.create(
          null,
          supportDir.path,
          dbName,
        );
        expect(await _ftsMatches(reopened, 'plainmarker'), 1);
        expect(await _ftsMatches(reopened, 'htmlmarker'), 0);

        await reopened.close();
        if (dbFile.existsSync()) dbFile.deleteSync();
      },
    );

    test('search schema survives repeated opens', () async {
      // AppDatabase.create runs initSchema on two connections, and every
      // launch runs it again. A CREATE that is not IF NOT EXISTS, or a
      // rebuild that is not version-gated, would throw on the second pass —
      // breaking app start rather than just search.
      final supportDir = await getApplicationSupportDirectory();
      const dbName = 'search_idempotency_test.db';
      final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
      if (dbFile.existsSync()) dbFile.deleteSync();

      var appDb = await AppDatabase.create(null, supportDir.path, dbName);
      await appDb.close();
      appDb = await AppDatabase.create(null, supportDir.path, dbName);
      await appDb.close();
      appDb = await AppDatabase.create(null, supportDir.path, dbName);

      final tables =
          (await appDb.rawDb.select(
            "SELECT name FROM sqlite_master WHERE name IN "
            "('emails_fts', 'files_fts', 'emails_contacts', 'contacts')",
          )).map((r) => r['name'] as String).toSet();
      expect(
        tables,
        containsAll(['emails_fts', 'files_fts', 'emails_contacts']),
      );
      // A fresh database must never carry the pre-rename table. The rename
      // migration is a no-op here, so its presence would mean the old DDL had
      // been left behind somewhere alongside the new.
      expect(tables, isNot(contains('contacts')));

      await appDb.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test(
      'startBackgroundServices should be deferred when vault is locked and start when unlocked',
      () async {
        final supportPath = await getApplicationSupportDirectory();
        final configFile = io.File(p.join(supportPath.path, 'config.json'));

        configFile.createSync(recursive: true);
        configFile.writeAsStringSync(jsonEncode({'path': tempDir!.path}));

        await DatabaseManager.instance.initializeDatabase();

        expect(DatabaseManager.instance.database, isNotNull);
        // Background services should not throw or fail when started or stopped
        await DatabaseManager.instance.startBackgroundServices();
        DatabaseManager.instance.stopBackgroundServices();

        configFile.deleteSync();
        DatabaseManager.instance.dispose();
      },
    );
  });
}

/// Column names currently on the `files` table.
Future<Set<String>> _fileColumns(AppDatabase db) async {
  final rows = await db.rawDb.select('PRAGMA table_info(files)');
  return rows.map((r) => r['name'] as String).toSet();
}

/// Number of `emails_fts` rows matching [match].
Future<int> _ftsMatches(AppDatabase db, String match) async {
  final rows = await db.rawDb.select(
    'SELECT count(*) AS c FROM emails_fts WHERE emails_fts MATCH ?',
    [match],
  );
  return rows.first['c'] as int;
}

Future<void> _insertEmail(
  AppDatabase db, {
  required String id,
  required String subject,
  String from = 'bob@example.com',
  String body = '',
}) async {
  await db.rawDb.execute(
    'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
    'plain_body) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [id, 'col-1', 0, from, 'me@example.com', subject, body],
  );
}
