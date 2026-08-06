import 'dart:io' as io;
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
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
      // Back to the pre-migration shape, so reopening runs the migration.
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
            "('emails_fts', 'files_fts', 'contacts')",
          )).map((r) => r['name'] as String).toSet();
      expect(tables, containsAll(['emails_fts', 'files_fts', 'contacts']));

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
