@Tags(['imap'])
library;

import 'dart:io';
import 'dart:isolate';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/scanners/imap_scanner_isolate.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/scan_write_relay.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';

import '../helpers/imap_test_server.dart';

/// Drives the real IMAP worker against the Dovecot container with a real
/// (temp) database, relaying writes the way the main isolate does.
void main() {
  late bool available;
  late Directory tempDir;
  late DatabaseManager manager;
  ImapClient? seeder;

  setUpAll(() async {
    available = await isImapTestServerAvailable();
  });

  setUp(() async {
    if (!available) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('imap_scanner_it_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((_) async => tempDir.path);
    manager = DatabaseManager.instance;
    await manager.initializeDatabase();
    seeder = await connectImapTestClient();
    await deleteAll(seeder!, 'INBOX');
  });

  tearDown(() async {
    if (!available) return;
    try {
      await seeder?.logout();
    } catch (_) {}
    seeder = null;
    manager.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Collection otherCollection() => Collection(
    id: 'imap-it',
    name: imapTestUserAlice,
    path: imapTestUserAlice,
    type: 'email',
    scanner: 'email.imap',
    scanStatus: 'idle',
    needsReAuth: false,
    emailProviderId: 'other',
    imapSettings:
        const ImapSettings(
          host: imapTestHost,
          port: imapTestPort,
          security: ImapSecurity.none,
          username: imapTestUserAlice,
        ).toJsonString(),
    accessToken: imapTestPassword,
  );

  /// Stores the row without its credential (the test vault is locked); the
  /// in-memory collection handed to the worker still carries it.
  Future<void> persist(Collection c) async {
    final token = c.accessToken;
    c.accessToken = null;
    await CollectionRepository(manager.database!).addCollection(c);
    c.accessToken = token;
  }

  /// Runs one sync job in-process; returns the messages the worker sent.
  Future<List<Object?>> runSync(Collection collection) async {
    final port = ReceivePort();
    final queue = SequentialWriteQueue();
    final seen = <Object?>[];
    port.listen((m) {
      if (tryHandleScanWrite(m, queue)) return;
      seen.add(m);
    });
    try {
      await ImapScannerIsolateWorker.execute({
        'token': null,
        'port': port.sendPort,
        'collection': collection,
        'folderId': null,
        'lastScanDate': null,
        'force': true,
        'appDir': tempDir.path,
        'dbDir': manager.databaseDirectoryPath!,
        'vaultDek': null,
      });
    } finally {
      port.close();
    }
    return seen;
  }

  void imapTest(String name, Future<void> Function() body) {
    test(name, () async {
      if (!available) {
        markTestSkipped('IMAP test server not running (make imap-test-up)');
        return;
      }
      await body();
    }, tags: 'imap');
  }

  imapTest('syncs INBOX emails and classifies folders by SPECIAL-USE', () async {
    final collection = otherCollection();
    await persist(collection);
    final uids = await seedMessages(seeder!, 'INBOX', [
      SeedMessage(
        messageId: '<it-1@test.local>',
        subject: 'First',
        date: DateTime.utc(2026, 1, 1, 10),
      ),
      SeedMessage(
        messageId: '<it-2@test.local>',
        subject: 'Second',
        date: DateTime.utc(2026, 1, 2, 10),
      ),
      SeedMessage(
        messageId: '<it-3@test.local>',
        subject: 'Third',
        date: DateTime.utc(2026, 1, 3, 10),
      ),
    ]);

    await runSync(collection);

    final db = manager.database!;
    final emails = await db.select(
      'SELECT uid, subject, folder_id, message_id FROM emails '
      'WHERE collection_id = ? ORDER BY uid',
      [collection.id],
    );
    expect(emails.map((e) => e['uid']), uids);
    expect(emails.map((e) => e['subject']), ['First', 'Second', 'Third']);
    expect(emails.map((e) => e['folder_id']).toSet(), {'INBOX'});

    final folders = await db.select(
      'SELECT id, name, type, path FROM email_folders WHERE collection_id = ?',
      [collection.id],
    );
    final roleByName = {for (final f in folders) f['name']: f['type']};
    expect(roleByName['INBOX'], 'inbox');
    expect(roleByName['Sent Items'], 'sent');
    expect(roleByName['Papierkorb'], 'trash');
    for (final f in folders) {
      expect(f['id'], f['path'], reason: 'folder id is the full IMAP path');
    }

    final status = await db.select(
      'SELECT scan_status FROM collections WHERE id = ?',
      [collection.id],
    );
    expect(status.single['scan_status'], 'ready');
  });

  imapTest(
    'wrong password writes no mail and marks the scan as error',
    () async {
      final collection = otherCollection()..accessToken = 'wrong';
      await persist(collection);
      await seedMessages(seeder!, 'INBOX', [
        SeedMessage(
          messageId: '<it-bad@test.local>',
          subject: 'x',
          date: DateTime.utc(2026, 1, 1),
        ),
      ]);

      await runSync(collection);

      final emails = await manager.database!.select(
        'SELECT id FROM emails WHERE collection_id = ?',
        [collection.id],
      );
      expect(emails, isEmpty);
      final status = await manager.database!.select(
        'SELECT scan_status FROM collections WHERE id = ?',
        [collection.id],
      );
      expect(status.single['scan_status'], 'error');
    },
  );

  imapTest(
    'unresolvable provider marks the collection scan status as error',
    () async {
      final collection = otherCollection()..imapSettings = null;
      await persist(collection);

      await runSync(collection);

      final status = await manager.database!.select(
        'SELECT scan_status FROM collections WHERE id = ?',
        [collection.id],
      );
      expect(status.single['scan_status'], 'error');
    },
  );
}
