import 'dart:io' as io;

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/app.dart' as m;

import 'package:collection/collection.dart';
import 'package:drift/isolate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseRepository', () {
    late DatabaseManager databaseManager;
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
      databaseManager = DatabaseManager.instance; //dbName
      databaseManager.useMemoryDb = true;
      databaseManager.appDatabase = AppDatabase(
        null,
        null,
        null,
        true,
      );
    });

    tearDown(() async {
      await databaseManager.database?.close();

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
    test('check Apps tables exists', () async {
      var tables = DatabaseManager.instance.database?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is m.Apps;
      });
      expect(t != null, true);
    });

    test("check all properties are saved", () async {
      m.App app = m.App(
        id: const Uuid().v4().toString(),
        name: "test app #1",
        slug: "test_app_1",
        group: "files",
        order: 1,
        route: "/app/1",
      );
      var db = databaseManager.database;
      await db?.into(db.apps).insert(app);

      List<m.App> allItems = await db?.select(db.apps).get() ?? [];

      // 5 apps are added by _loadInitialData
      expect(allItems.length, equals(6));
      m.App? savedApp = allItems.firstWhereOrNull((a) => a.id == app.id);
      expect(savedApp, isNotNull);
      expect(savedApp?.id, equals(app.id));
      expect(savedApp?.name, equals(app.name));
      expect(savedApp?.slug, equals(app.slug));
      expect(savedApp?.group, equals(app.group));
      expect(savedApp?.order, equals(app.order));
      expect(savedApp?.icon, equals(app.icon));
      expect(savedApp?.route, equals(app.route));
    });

    test("Get By App ID", () async {
      m.App app = m.App(
        id: const Uuid().v4().toString(),
        name: "test app #1",
        slug: "test_app_1",
        group: "files",
        order: 1,
        route: "/app/1",
      );
      var db = databaseManager.database;
      await db?.into(db.apps).insert(app);

      m.App? dbApp =
          await (db?.select(db.apps)
            ?..where((a) => a.id.equals(app.id)))?.getSingle();
      expect(dbApp, isNotNull);
      expect(dbApp?.id, equals(app.id));
    });

    test("Insert multiple Apps", () async {
      m.App app1 = m.App(
        id: const Uuid().v4().toString(),
        name: "test app #1",
        slug: "test_app_1",
        group: "files",
        order: 1,
        route: "/app/1",
      );
      m.App app2 = m.App(
        id: const Uuid().v4().toString(),
        name: "test app #2",
        slug: "test_app_2",
        group: "files",
        order: 1,
        route: "/app/2",
      );
      m.App app3 = m.App(
        id: const Uuid().v4().toString(),
        name: "test app #3",
        slug: "test_app_3",
        group: "files",
        order: 1,
        route: "/app/3",
      );
      var db = databaseManager.database;
      await db?.into(db.apps).insert(app1);
      await db?.into(db.apps).insert(app2);
      await db?.into(db.apps).insert(app3);

      List<m.App> allItems = await db?.select(db.apps).get() ?? [];

      // 5 from initial data + 3 from test
      expect(allItems.length, equals(8));
    });

    test("Check Unique Constraint in Apps", () async {
      m.App app1 = m.App(
        id: const Uuid().v4().toString(),
        name: "test app #1",
        slug: "test_app_1",
        group: "files",
        order: 1,
        route: "/app/1",
      );
      m.App app2 = m.App(
        id: const Uuid().v4().toString(),
        name: "test app #1",
        slug: "test_app_1",
        group: "files",
        order: 1,
        route: "/app/1",
      );

      var db = databaseManager.database;

      expect(() async {
        await db?.into(db.apps).insert(app1);
        await db?.into(db.apps).insert(app2);
      }, throwsA(isA<Exception>())); // SqliteException or similar
    });
  });
}
