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
