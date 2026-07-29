import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';

/// The mail list is paged with LIMIT/OFFSET over a sorted query, and mail
/// routinely ties on the sort column: a PST import stamps thousands of
/// messages with the same date, and mailing lists repeat a sender or a
/// subject. SQLite gives no guarantee about the relative order of tied rows
/// between executions, and each page is a separate execution — so without a
/// unique tiebreaker the user can scroll past a message that was never shown
/// and see another one twice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Email paging is stable across ties', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();

      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_page_');
      const MethodChannel channel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            return tempDir.path;
          });

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('tied messages page in id order, each exactly once', () async {
      final colId = const Uuid().v4();
      // One timestamp for all of them — the shape a bulk import produces.
      const sameDate = 1700000000000;
      const total = 40;

      // Inserted in an order that is deliberately not id order, so "whatever
      // the scan happens to return" and "ordered by id" are distinguishable.
      // Insertion order is what an unordered scan gives back, and asserting
      // against it would pass with no tiebreaker at all.
      final ids = [
        for (var i = 0; i < total; i++) 'msg-${i.toString().padLeft(3, '0')}',
      ];
      for (final id in ids.reversed) {
        await db.execute(
          'INSERT INTO emails (id, collection_id, date, "from", "to", '
          'subject, is_deleted) VALUES (?, ?, ?, ?, ?, ?, 0)',
          [
            id,
            colId,
            sameDate,
            'sender@example.com',
            'me@example.com',
            'Same subject',
          ],
        );
      }

      final repo = EmailRepository(db);
      final seen = <String>[];
      for (var offset = 0; offset < total; offset += 10) {
        final page = await repo.emails(colId, limit: 10, offset: offset);
        seen.addAll(page.map((e) => e.id));
      }

      expect(
        seen,
        ids,
        reason:
            'tied rows must come back in one defined order across pages — '
            'otherwise a message can be skipped by one page and repeated by '
            'the next',
      );
      expect(seen.toSet().length, total);
    });
  });
}
