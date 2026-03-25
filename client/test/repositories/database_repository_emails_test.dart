import 'dart:io' as io;

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email.dart' as m;

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:path_provider/path_provider.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseRepository', () {

    io.Directory? path;
    String dbName = 'test-${DateTime.now().millisecondsSinceEpoch}.sqlite';

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

    test('check Collections tables exists', () async {
      print("closing database");
      var tables = (DatabaseManager.instance.database)?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is m.Emails;
      });
      expect(t != null, true);
    });

    test("Delete Email", () async {

      //var db = DatabaseManager.instance.database;
      //await db?.into(db?.emails).insert(email);

      // List<m.Email> allItems = await db?.select(db?.emails).get() ?? [];
      // expect(allItems.length, equals(1));

      // await db?.delete(db?.emails).delete(email);

      // List<m.Email> afterDeleteItems = await db?.select(db?.emails).get();
      // expect(afterDeleteItems.length, equals(0));
      fail("todo");
    });

    test("check all properties are saved", () async {


      //var db = DatabaseManager.instance.database;
      //await db?.into(db?.emails).insert(email);

      // List<m.Email> allItems = await db?.select(db?.emails).get();

      // expect(allItems.length, equals(1));
      // expect(allItems[0].id, equals(email.id));
      // expect(allItems[0].from, equals(email.from));
      // expect(allItems[0].to, equals(email.to));
      // expect(allItems[0].cc, equals(email.cc));
      // expect(allItems[0].labels, equals(email.labels));
      // expect(allItems[0].subject, equals(email.subject));
      // expect(allItems[0].date.difference(email.date).inSeconds, equals(0));

      // await db.delete(db.emails).delete(email);
      fail("todo");
    });

    test("Insert multiple files", () async {


      // var db = await databaseRepository.database;
      // await db.into(db.emails).insert(email1);
      // await db.into(db.emails).insert(email2);
      // await db.into(db.emails).insert(email3);

      // List<m.Email> allItems = await db.select(db.emails).get();

      // expect(allItems.length, equals(3));

      // await db.delete(db.emails).delete(email1);
      // await db.delete(db.emails).delete(email2);
      // await db.delete(db.emails).delete(email3);
      fail("todo");
    });
  });
}
