import 'dart:io' as io;

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseRepository', () {

    io.Directory? path;
    String dbName = 'test-${DateTime.now().millisecondsSinceEpoch}.sqllite';

    setUpAll(() async {
      //https://github.com/flutter/flutter/issues/10912#issuecomment-587403632
      TestWidgetsFlutterBinding.ensureInitialized();

      const MethodChannel channel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall methodCall) async {
        return ".";
      });

      path = await getTemporaryDirectory();
    });

    tearDownAll(() async {
      //DatabaseManager.instance.database.close();

      if (path != null) {
        io.File f = io.File("data/$dbName");
        if (f.existsSync()) {
          f.deleteSync();
        }
      }
    });

    test('check instance not null', () {
      expect(DatabaseManager.instance, isNotNull);
    });

    test('check schema version', () async {
      //expect( DatabaseManager.instance.database.schemaVersion, 1);
    });

    test('check Emails tables exists', () async {
      var tables = (DatabaseManager.instance.database)?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is Emails;
      });
      expect(t != null, true);
    });

    test('check Files tables exists', () async {
      var tables = (DatabaseManager.instance.database)?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is Files;
      });
      expect(t != null, true);
    });

    test('check Folders tables exists', () async {
      var tables = (DatabaseManager.instance.database)?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is Folders;
      });
      expect(t != null, true);
    });
  });
}
