import 'dart:io' as io;
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:path_provider/path_provider.dart';
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

  });
}
