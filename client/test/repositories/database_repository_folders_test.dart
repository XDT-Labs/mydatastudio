import 'dart:io' as io;

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/folder.dart' as m;

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseRepository', () {
    io.Directory? path;
    String dbName = 'test-${DateTime.now().millisecondsSinceEpoch}.sqllite';

    setUp(() async {
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
      DatabaseManager.instance.useMemoryDb = true;
      DatabaseManager.instance.appDatabase = AppDatabase(
        null,
        null,
        null,
        true,
      );
    });

    tearDown(() async {
      await DatabaseManager.instance.database?.close();

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
      var tables = DatabaseManager.instance.database?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is m.Folders;
      });
      expect(t != null, true);
    });

    test("Delete Folder", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

      m.Folder folder = m.Folder(
        id: const Uuid().v4().toString(),
        name: "test folder",
        path: "/test",
        parent: "/",
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: const Uuid().v4().toString(),
      );

      await db.into(db.folders).insert(folder);

      List<m.Folder> allItems = await db.select(db.folders).get();
      expect(allItems.length, equals(1));

      await db.delete(db.folders).delete(folder);

      List<m.Folder> afterDeleteItems = await db.select(db.folders).get();
      expect(afterDeleteItems.length, equals(0));
    });

    test("check all properties are saved", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

      String folderId = const Uuid().v4().toString();
      String collectionId = const Uuid().v4().toString();
      DateTime now = DateTime.now();

      m.Folder folder = m.Folder(
        id: folderId,
        name: "test folder",
        path: "/test",
        parent: "/",
        dateCreated: now,
        dateLastModified: now,
        collectionId: collectionId,
        thumbnail: "thumb",
        downloadUrl: "url",
        emailId: "email123",
      );

      await db.into(db.folders).insert(folder);

      List<m.Folder> allItems = await db.select(db.folders).get();

      expect(allItems.length, equals(1));
      expect(allItems[0].id, equals(folderId));
      expect(allItems[0].name, equals("test folder"));
      expect(allItems[0].path, equals("/test"));
      expect(allItems[0].parent, equals("/"));
      expect(allItems[0].dateCreated.difference(now).inSeconds, equals(0));
      expect(allItems[0].dateLastModified.difference(now).inSeconds, equals(0));
      expect(allItems[0].collectionId, equals(collectionId));
      expect(allItems[0].thumbnail, equals("thumb"));
      expect(allItems[0].downloadUrl, equals("url"));
      expect(allItems[0].emailId, equals("email123"));
    });

    test("Insert multiple folders", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

      String collectionId = const Uuid().v4().toString();

      m.Folder folder1 = m.Folder(
        id: const Uuid().v4().toString(),
        name: "folder 1",
        path: "/1",
        parent: "/",
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: collectionId,
      );
      m.Folder folder2 = m.Folder(
        id: const Uuid().v4().toString(),
        name: "folder 2",
        path: "/2",
        parent: "/",
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: collectionId,
      );

      await db.into(db.folders).insert(folder1);
      await db.into(db.folders).insert(folder2);

      List<m.Folder> allItems = await db.select(db.folders).get();
      expect(allItems.length, equals(2));
    });
  });
}
