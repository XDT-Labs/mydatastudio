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

    test('initializeDatabase should setup database and repository with split storage and database config keys', () async {
      DatabaseManager.isTesting = false;
      final supportPath = await getApplicationSupportDirectory();
      final expectedDatabasePath = supportPath.path;
      final configFile = io.File(p.join(supportPath.path, 'config.json'));

      // Create dummy config file with split keys
      configFile.createSync(recursive: true);
      configFile.writeAsStringSync(jsonEncode({
        'storage': tempDir!.path,
        'database': expectedDatabasePath,
      }));

      await DatabaseManager.instance.initializeDatabase();

      expect(DatabaseManager.instance.storagePath, equals(tempDir!.path));
      expect(DatabaseManager.instance.databaseDirectoryPath, equals(expectedDatabasePath));
      expect(DatabaseManager.instance.database, isNotNull);
      expect(DatabaseManager.instance.repository, isNotNull);
      expect(DatabaseManager.isInitializedNotifier.value, isTrue);

      // Cleanup
      DatabaseManager.isTesting = true;
      configFile.deleteSync();
      DatabaseManager.instance.dispose();
    });

    test('initializeDatabase should throw FileSystemException if storage directory is inaccessible', () async {
      DatabaseManager.isTesting = false;
      final supportPath = await getApplicationSupportDirectory();
      final configFile = io.File(p.join(supportPath.path, 'config.json'));

      // Use a storage path that cannot be accessed or created
      const inaccessiblePath = '/non_existent_volume_xyz_123/storage_dir';

      configFile.createSync(recursive: true);
      configFile.writeAsStringSync(jsonEncode({
        'storage': inaccessiblePath,
      }));

      expect(
        () => DatabaseManager.instance.initializeDatabase(),
        throwsA(isA<io.FileSystemException>()),
      );

      // Cleanup
      DatabaseManager.isTesting = true;
      configFile.deleteSync();
      DatabaseManager.instance.dispose();
    });

    test('testPathSupportsWal should return true for local temporary path', () async {
      final testPath = p.join(tempDir!.path, 'wal_test_dir');
      final supports = await DatabaseManager.testPathSupportsWal(testPath);
      expect(supports, isTrue);

      // Clean up test dir
      final dir = io.Directory(testPath);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test('AppDatabase.create should redirect to application support directory if path does not support WAL', () async {
      // We pass a non-existent invalid path which will cause testPathSupportsWal to return false
      const nonWalPath = '/invalid_path_non_existent';
      final appDb = await AppDatabase.create(null, nonWalPath, 'redirect_test.db');
      
      // It should have redirected to application support directory (which is local and supports WAL)
      final supportDir = await getApplicationSupportDirectory();
      expect(appDb.path, equals(supportDir.path));

      // Clean up the test database file
      await appDb.close();
      final dbFile = io.File(p.join(supportDir.path, 'data', 'redirect_test.db'));
      if (dbFile.existsSync()) {
        dbFile.deleteSync();
      }
    });

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

    test(
      'adding files.is_inline backfills already-imported mail',
      () async {
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
      },
    );

    test('getRealApplicationSupportPath should return correct path even if PathProviderPlatform is overridden', () async {
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
      expect(overridenSupportDir.path, equals('/some_custom_overridden_path'));

      // getRealApplicationSupportPath should still return original
      final realPathAfterOverride = await DatabaseManager.getRealApplicationSupportPath();
      expect(realPathAfterOverride, equals(originalSupportDir.path));

      // Restore platform
      PathProviderPlatform.instance = oldPlatform;
    });
  });
}

/// Column names currently on the `files` table.
Future<Set<String>> _fileColumns(AppDatabase db) async {
  final rows = await db.rawDb.select('PRAGMA table_info(files)');
  return rows.map((r) => r['name'] as String).toSet();
}
