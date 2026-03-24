import 'dart:io' as io;

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/file.dart' as m;

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseRepository', () {
    //late DatabaseManager databaseRepository;
    io.Directory? path;
    //String dbName = 'test-${DateTime.now().millisecondsSinceEpoch}.sqllite';

    setUpAll(() async {
      //final Uri basedir = (goldenFileComparator as LocalFileComparator).basedir;

      //https://github.com/flutter/flutter/issues/10912#issuecomment-587403632
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return ".";
      });

      path = await getTemporaryDirectory();
    });

    tearDownAll(() async {
      //(await databaseRepository.database).close();

      if (path != null) {
        /*
        io.File f = io.File("data/$dbName");
        if (f.existsSync()) {
          f.deleteSync();
        }
        */
      }
    });

    test('check instance not null', () {
      expect(DatabaseManager.instance, isNotNull);
    });

    //Apps, AppUsers, Collections, Emails, Files, Folders
    test('check Collections tables exists', () async {
      print("closing database");
      var tables = DatabaseManager.instance.database?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is m.Files;
      });
      expect(t != null, true);
    });

    test("Delete File", () async {
      /*
      m.File file = m.File(
        id: const Uuid().v4().toString(),
        name: "foo.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: DateTime.now().subtract(const Duration(days: 1)),
        dateLastModified: DateTime.now(),
        collectionId: const Uuid().v4().toString(),
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
      );
      */
      // var db = DatabaseManager.instance.database;
      // await db?.into(db?.files).insert(file);

      // List<m.File> allItems = await db?.select(db?.files).get();
      // expect(allItems.length, equals(1));

      // await db?.delete(db?.files).delete(file);

      // List<m.File> afterDeleteItems = await db?.select(db?.files).get();
      // expect(afterDeleteItems.length, equals(0));
      fail("not implemented");
    });

    test("check all properties are saved", () async {
      /*
      m.File file = m.File(
        id: const Uuid().v4().toString(),
        name: "foo.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: DateTime.now().subtract(const Duration(days: 1)),
        dateLastModified: DateTime.now(),
        collectionId: const Uuid().v4().toString(),
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
      );
      */

      // var db = await DatabaseManager.instance.database;
      // await db?.into(db?.files).insert(file);

      // List<m.File> allItems = await db?.select(db?.files).get();

      // expect(allItems.length, equals(1));
      // expect(allItems[0].id, equals(file.id));
      // expect(allItems[0].name, equals(file.name));
      // expect(allItems[0].path, equals(file.path));
      // expect(allItems[0].parent, equals(file.parent));
      // expect(
      //   allItems[0].dateCreated.difference(file.dateCreated).inSeconds,
      //   equals(0),
      // );
      // expect(
      //   allItems[0].dateLastModified
      //       .difference(file.dateLastModified)
      //       .inSeconds,
      //   equals(0),
      // );
      // expect(allItems[0].collectionId, equals(file.collectionId));
      // expect(allItems[0].contentType, equals(file.contentType));
      // expect(allItems[0].isDeleted, equals(file.isDeleted));
      // expect(allItems[0].size, equals(file.size));

      // await db.delete(db.files).delete(file);
      fail("not implemented");
    });

    test("Insert multiple files", () async {
      /*
      m.File file1 = m.File(
        id: const Uuid().v4().toString(),
        name: "foo1.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: DateTime.now().subtract(const Duration(days: 1)),
        dateLastModified: DateTime.now(),
        collectionId: const Uuid().v4().toString(),
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
      );
      m.File file2 = m.File(
        id: const Uuid().v4().toString(),
        name: "foo2.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: DateTime.now().subtract(const Duration(days: 1)),
        dateLastModified: DateTime.now(),
        collectionId: const Uuid().v4().toString(),
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
      );
      m.File file3 = m.File(
        id: const Uuid().v4().toString(),
        name: "foo3.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: DateTime.now().subtract(const Duration(days: 1)),
        dateLastModified: DateTime.now(),
        collectionId: const Uuid().v4().toString(),
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
      );
      */

      // var db = await databaseRepository.database;
      // await db.into(db.files).insert(file1);
      // await db.into(db.files).insert(file2);
      // await db.into(db.files).insert(file3);

      // List<m.File> allItems = await db.select(db.files).get();

      // expect(allItems.length, equals(3));

      // await db.delete(db.files).delete(file1);
      // await db.delete(db.files).delete(file2);
      // await db.delete(db.files).delete(file3);
      fail("not implemented");
    });
  });
}
