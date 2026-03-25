import 'dart:io' as io;

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/folder.dart' as m;

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
      //final Uri basedir = (goldenFileComparator as LocalFileComparator).basedir;

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
      //(await databaseRepository.database).close();

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

    //Apps, AppUsers, Collections, Emails, Files, Folders
    test('check folders tables exists', () async {
      print("closing database");
      var tables = DatabaseManager.instance.database?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is m.Folders;
      });
      expect(t != null, true);
    });

    test("Delete Folder", () async {
      fail("not implemented");
    });

    test("check all properties are saved", () async {
      fail("not implemented");
    });

    test("Insert multiple folders", () async {
      fail("not implemented");
    });
  });
}
