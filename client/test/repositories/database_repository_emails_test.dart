import 'dart:io' as io;

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email.dart' as m;

import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:path_provider/path_provider.dart';


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatabaseRepository', () {

    io.Directory? path;
    String dbName = 'test-${DateTime.now().millisecondsSinceEpoch}.sqlite';

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

    test('check Emails tables exists', () async {
      var tables = (DatabaseManager.instance.database)?.allTables;

      var t = tables?.firstWhereOrNull((e) {
        return e is m.Emails;
      });
      expect(t != null, true);
    });

    test("Delete Email", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

      m.Email email = m.Email(
        id: const Uuid().v4().toString(),
        collectionId: const Uuid().v4().toString(),
        date: DateTime.now(),
        from: "sender@example.com",
        to: ["receiver@example.com"],
        subject: "Test Subject",
        isDeleted: false,
      );

      await db.into(db.emails).insert(email);

      List<m.Email> allItems = await db.select(db.emails).get();
      expect(allItems.length, equals(1));

      await db.delete(db.emails).delete(email);

      List<m.Email> afterDeleteItems = await db.select(db.emails).get();
      expect(afterDeleteItems.length, equals(0));
    });

    test("check all properties are saved", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

      String emailId = const Uuid().v4().toString();
      String collectionId = const Uuid().v4().toString();
      DateTime now = DateTime.now();

      m.Email email = m.Email(
        id: emailId,
        collectionId: collectionId,
        date: now,
        from: "sender@example.com",
        to: ["receiver1@example.com", "receiver2@example.com"],
        cc: ["cc@example.com"],
        subject: "Test Subject",
        snippet: "This is a snippet",
        htmlBody: "<html><body>Body</body></html>",
        plainBody: "Body",
        labels: ["INBOX", "SENT"],
        headers: "Headers content",
        folderId: "folder123",
        messageId: "msg123",
        threadId: "thread123",
        uid: 1001,
        isRead: true,
        hasAttachments: true,
        isDeleted: false,
      );

      await db.into(db.emails).insert(email);

      List<m.Email> allItems = await db.select(db.emails).get();

      expect(allItems.length, equals(1));
      expect(allItems[0].id, equals(emailId));
      expect(allItems[0].collectionId, equals(collectionId));
      expect(allItems[0].date.difference(now).inSeconds, equals(0));
      expect(allItems[0].from, equals("sender@example.com"));
      expect(allItems[0].to, equals(["receiver1@example.com", "receiver2@example.com"]));
      expect(allItems[0].cc, equals(["cc@example.com"]));
      expect(allItems[0].subject, equals("Test Subject"));
      expect(allItems[0].snippet, equals("This is a snippet"));
      expect(allItems[0].htmlBody, equals("<html><body>Body</body></html>"));
      expect(allItems[0].plainBody, equals("Body"));
      expect(allItems[0].labels, equals(["INBOX", "SENT"]));
      expect(allItems[0].headers, equals("Headers content"));
      expect(allItems[0].folderId, equals("folder123"));
      expect(allItems[0].messageId, equals("msg123"));
      expect(allItems[0].threadId, equals("thread123"));
      expect(allItems[0].uid, equals(1001));
      expect(allItems[0].isRead, equals(true));
      expect(allItems[0].hasAttachments, equals(true));
      expect(allItems[0].isDeleted, equals(false));
    });

    test("Insert multiple emails", () async {
      var db = DatabaseManager.instance.database;
      if (db == null) {
        fail("database is null");
      }

      String collectionId = const Uuid().v4().toString();

      m.Email email1 = m.Email(
        id: const Uuid().v4().toString(),
        collectionId: collectionId,
        date: DateTime.now(),
        from: "user1@example.com",
        to: ["user2@example.com"],
        isDeleted: false,
      );
      m.Email email2 = m.Email(
        id: const Uuid().v4().toString(),
        collectionId: collectionId,
        date: DateTime.now(),
        from: "user2@example.com",
        to: ["user1@example.com"],
        isDeleted: false,
      );

      await db.into(db.emails).insert(email1);
      await db.into(db.emails).insert(email2);

      List<m.Email> allItems = await db.select(db.emails).get();
      expect(allItems.length, equals(2));
    });
  });
}
