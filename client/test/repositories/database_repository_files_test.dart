import 'dart:io' as io;

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/file.dart' as m;

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseRepository', () {
    io.Directory? path;

    setUp(() async {
      //https://github.com/flutter/flutter/issues/10912#issuecomment-587403632
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
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
    });

    test('check instance not null', () {
      expect(DatabaseManager.instance, isNotNull);
    });

    //Apps, AppUsers, Collections, Emails, Files, Folders
    test('check Files tables exists', () async {
      var tables = DatabaseManager.instance.database?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is m.Files;
      });
      expect(t != null, true);
    });

    test("Delete File", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

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

      await db.into(db.files).insert(file);

      List<m.File> allItems = await db.select(db.files).get();
      expect(allItems.length, equals(1));

      await db.delete(db.files).delete(file);

      List<m.File> afterDeleteItems = await db.select(db.files).get();
      expect(afterDeleteItems.length, equals(0));
    });

    test("check all properties are saved", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

      String fileId = const Uuid().v4().toString();
      String collectionId = const Uuid().v4().toString();
      DateTime dateCreated = DateTime.now().subtract(const Duration(days: 1));
      DateTime dateLastModified = DateTime.now();

      m.File file = m.File(
        id: fileId,
        name: "foo.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: dateCreated,
        dateLastModified: dateLastModified,
        collectionId: collectionId,
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
        thumbnail: "thumb",
        downloadUrl: "url",
        emailId: "email123",
        latitude: 12.34,
        longitude: 56.78,
        localPath: "/local/path",
      );

      await db.into(db.files).insert(file);

      List<m.File> allItems = await db.select(db.files).get();

      expect(allItems.length, equals(1));
      expect(allItems[0].id, equals(fileId));
      expect(allItems[0].name, equals("foo.jpg"));
      expect(allItems[0].path, equals("/pics"));
      expect(allItems[0].parent, equals("/MyPhotos"));
      expect(
        allItems[0].dateCreated.difference(dateCreated).inSeconds,
        equals(0),
      );
      expect(
        allItems[0].dateLastModified
            .difference(dateLastModified)
            .inSeconds,
        equals(0),
      );
      expect(allItems[0].collectionId, equals(collectionId));
      expect(allItems[0].contentType, equals("image/jpeg"));
      expect(allItems[0].isDeleted, equals(false));
      expect(allItems[0].size, equals(101));
      expect(allItems[0].thumbnail, equals("thumb"));
      expect(allItems[0].downloadUrl, equals("url"));
      expect(allItems[0].emailId, equals("email123"));
      expect(allItems[0].latitude, equals(12.34));
      expect(allItems[0].longitude, equals(56.78));
      expect(allItems[0].localPath, equals("/local/path"));
    });

    test("Insert multiple files", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

      String collectionId = const Uuid().v4().toString();

      m.File file1 = m.File(
        id: const Uuid().v4().toString(),
        name: "foo1.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: collectionId,
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
      );
      m.File file2 = m.File(
        id: const Uuid().v4().toString(),
        name: "foo2.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: collectionId,
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
      );
      m.File file3 = m.File(
        id: const Uuid().v4().toString(),
        name: "foo3.jpg",
        path: "/pics",
        parent: "/MyPhotos",
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: collectionId,
        contentType: "image/jpeg",
        size: 101,
        isDeleted: false,
      );

      await db.into(db.files).insert(file1);
      await db.into(db.files).insert(file2);
      await db.into(db.files).insert(file3);

      List<m.File> allItems = await db.select(db.files).get();
      expect(allItems.length, equals(3));
    });
  });
}
