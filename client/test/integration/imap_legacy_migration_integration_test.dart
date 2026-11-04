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
import 'package:uuid/uuid.dart';

import '../helpers/imap_test_server.dart';

/// Collections synced by the pre-engine Yahoo/Outlook isolates must move to the
/// IMAP engine without re-downloading mail or duplicating rows.
///
/// The legacy shape (git show 651b128^:.../yahoo_scanner_isolate.dart):
///   emails.id         = the raw Message-ID, or a v5 uuid of
///                       'email:<yahoo|outlook>:<cid>:<folder>:<uid>' without one
///   emails.uid        = the IMAP UID, folder_id = mailbox name, is_read = 0
///   email_folders     = id = mailbox name, no uid_validity / last_synced_uid
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
    tempDir = await Directory.systemTemp.createTemp('imap_legacy_it_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((_) async => tempDir.path);
    manager = DatabaseManager.instance;
    await manager.initializeDatabase();
    seeder = await connectImapTestClient(user: imapTestUserBob);
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

  const cid = 'imap-legacy';

  Future<Collection> persisted() async {
    final c = Collection(
      id: cid,
      name: imapTestUserBob,
      path: imapTestUserBob,
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
            username: imapTestUserBob,
          ).toJsonString(),
      accessToken: imapTestPassword,
    );
    final token = c.accessToken;
    c.accessToken = null;
    await CollectionRepository(manager.database!).addCollection(c);
    c.accessToken = token;
    return c;
  }

  /// Runs one sync; returns the worker's log lines.
  Future<List<String>> sync(Collection collection) async {
    final port = ReceivePort();
    final queue = SequentialWriteQueue();
    final logs = <String>[];
    port.listen((m) {
      if (tryHandleScanWrite(m, queue)) return;
      if (m is Map && m['type'] == 'log') logs.add(m['message'] as String);
    });
    try {
      await ImapScannerIsolateWorker.execute({
        'token': null,
        'port': port.sendPort,
        'collection': collection,
        'folderId': null,
        'force': true,
        'fullResync': false,
        'appDir': tempDir.path,
        'dbDir': manager.databaseDirectoryPath!,
        'vaultDek': null,
      });
    } finally {
      port.close();
    }
    return logs;
  }

  /// A row exactly as the legacy isolate wrote it.
  Future<void> insertLegacyEmail({
    required String id,
    required int uid,
    required String? messageId,
    String folder = 'INBOX',
  }) => manager.database!.execute(
    'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
    'plain_body, folder_id, message_id, uid, is_read, is_deleted) '
    "VALUES (?, ?, 0, 'sender@example.com', 'bob@test.local', 'legacy', "
    "'LEGACY BODY', ?, ?, ?, 0, 0)",
    [id, cid, folder, messageId, uid],
  );

  Future<void> insertLegacyFolder(String name) => manager.database!.execute(
    'INSERT INTO email_folders (id, collection_id, name, type, '
    "messages_total, messages_unread) VALUES (?, ?, ?, 'user', 0, 0)",
    [name, cid, name],
  );

  void imapTest(String name, Future<void> Function() body) {
    test(name, () async {
      if (!available) {
        markTestSkipped('IMAP test server not running (make imap-test-up)');
        return;
      }
      await body();
    }, tags: 'imap');
  }

  test('messageIdlessEmailId reproduces the legacy Yahoo/Outlook ids', () {
    for (final provider in ['yahoo', 'outlook']) {
      expect(
        ImapScannerIsolateWorker.messageIdlessEmailId(
          provider,
          'c',
          'INBOX',
          7,
        ),
        const Uuid().v5(Namespace.url.value, 'email:$provider:c:INBOX:7'),
      );
    }
  });

  imapTest(
    'first engine sync adopts legacy rows: no new rows, no body downloads, '
    'uids and sync state recorded',
    () async {
      final c = await persisted();
      final withId = await seedMessages(seeder!, 'INBOX', [
        SeedMessage(
          messageId: '<legacy-1@test.local>',
          subject: 'one',
          date: DateTime.utc(2026, 1, 1),
          flags: [r'\Seen'],
        ),
        SeedMessage(
          messageId: '<legacy-2@test.local>',
          subject: 'two',
          date: DateTime.utc(2026, 1, 2),
        ),
      ]);
      // A message with no Message-ID header at all.
      final noIdResult = await seeder!.appendMessageText(
        [
          'Date: ${DateCodec.encodeDate(DateTime.utc(2026, 1, 3))}',
          'From: sender@example.com',
          'To: bob@test.local',
          'Subject: no id',
          '',
          'body',
          '',
        ].join('\r\n'),
        targetMailboxPath: 'INBOX',
      );
      final noIdUid =
          noIdResult.responseCodeAppendUid!.targetSequence.toList().single;

      await insertLegacyFolder('INBOX');
      await insertLegacyEmail(
        id: '<legacy-1@test.local>',
        uid: withId[0],
        messageId: '<legacy-1@test.local>',
      );
      await insertLegacyEmail(
        id: '<legacy-2@test.local>',
        uid: withId[1],
        messageId: '<legacy-2@test.local>',
      );
      final legacyNoIdId = ImapScannerIsolateWorker.messageIdlessEmailId(
        'other',
        cid,
        'INBOX',
        noIdUid,
      );
      await insertLegacyEmail(id: legacyNoIdId, uid: noIdUid, messageId: null);

      final logs = await sync(c);

      final db = manager.database!;
      final rows = await db.select(
        'SELECT id, uid, plain_body, is_read FROM emails '
        'WHERE collection_id = ? ORDER BY uid',
        [cid],
      );
      expect(rows, hasLength(3), reason: 'no duplicate rows');
      expect(rows.map((r) => r['uid']), [...withId, noIdUid]);
      expect(
        rows.every((r) => r['plain_body'] == 'LEGACY BODY'),
        isTrue,
        reason: 'stored rows were not overwritten by a re-download',
      );
      expect(rows.map((r) => r['is_read']), [
        1,
        0,
        0,
      ], reason: 'legacy rows (all unread) pick up the server seen flag');
      expect(
        logs,
        contains('INBOX: 0 message bodies downloaded.'),
        reason: 'only headers were fetched for messages already stored',
      );

      final st =
          (await db.select(
            'SELECT * FROM email_folders WHERE collection_id = ? AND id = ?',
            [cid, 'INBOX'],
          )).single;
      expect(st['uid_validity'], isNotNull);
      expect(st['last_synced_uid'], noIdUid);
      expect(st['uid_next'], isNotNull);

      // Next sync is incremental: a new message is the only body fetched.
      await seedMessages(seeder!, 'INBOX', [
        SeedMessage(
          messageId: '<legacy-3@test.local>',
          subject: 'three',
          date: DateTime.utc(2026, 1, 4),
        ),
      ]);
      final logs2 = await sync(c);
      expect(logs2, contains('INBOX: 1 message bodies downloaded.'));
      expect(
        await db.select('SELECT id FROM emails WHERE collection_id = ?', [cid]),
        hasLength(4),
      );
    },
  );

  imapTest('legacy rows with a message missing from the server are kept, '
      'new server mail is still downloaded', () async {
    final c = await persisted();
    final uids = await seedMessages(seeder!, 'INBOX', [
      SeedMessage(
        messageId: '<legacy-new@test.local>',
        subject: 'new',
        date: DateTime.utc(2026, 1, 1),
      ),
    ]);
    await insertLegacyFolder('INBOX');
    await insertLegacyEmail(
      id: '<legacy-gone@test.local>',
      uid: 4242,
      messageId: '<legacy-gone@test.local>',
    );

    final logs = await sync(c);

    final rows = await manager.database!.select(
      'SELECT message_id, uid, is_deleted FROM emails '
      'WHERE collection_id = ? ORDER BY message_id',
      [cid],
    );
    expect(logs, contains('INBOX: 1 message bodies downloaded.'));
    expect(rows.map((r) => r['message_id']), [
      '<legacy-gone@test.local>',
      '<legacy-new@test.local>',
    ]);
    expect(rows.last['uid'], uids.single);
    // Default delete policy keeps rows the server no longer has.
    expect(rows.first['is_deleted'], 0);
  });
}
