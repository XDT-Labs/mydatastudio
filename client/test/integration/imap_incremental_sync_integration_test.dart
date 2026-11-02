@Tags(['imap'])
library;

import 'dart:io';
import 'dart:isolate';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/scanners/imap_scanner_isolate.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/scan_write_relay.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';

import '../helpers/imap_test_server.dart';

/// Incremental sync (UID / UIDVALIDITY / CONDSTORE), Message-ID dedupe and the
/// delete policies, driven against the Dovecot container.
void main() {
  late bool available;
  late Directory tempDir;
  late DatabaseManager manager;
  ImapClient? seeder;

  const resetMailboxes = [
    'INBOX',
    'Sent',
    'Trash',
    'Archive',
    'Sent Items',
    'Papierkorb',
  ];
  const scratchMailbox = 'ItReval';

  setUpAll(() async {
    available = await isImapTestServerAvailable();
  });

  setUp(() async {
    if (!available) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('imap_incr_it_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((_) async => tempDir.path);
    manager = DatabaseManager.instance;
    await manager.initializeDatabase();
    seeder = await connectImapTestClient(user: imapTestUserBob);
    for (final m in resetMailboxes) {
      await deleteAll(seeder!, m);
    }
    await _dropMailbox(seeder!, scratchMailbox);
  });

  tearDown(() async {
    if (!available) return;
    try {
      await _dropMailbox(seeder!, scratchMailbox);
      await seeder?.logout();
    } catch (_) {}
    seeder = null;
    manager.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Collection newCollection(EmailDeletePolicy policy) => Collection(
    id: 'imap-incr',
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
    emailDeletePolicy: policy,
  );

  Future<Collection> persisted(EmailDeletePolicy policy) async {
    final c = newCollection(policy);
    final token = c.accessToken;
    c.accessToken = null;
    await CollectionRepository(manager.database!).addCollection(c);
    c.accessToken = token;
    return c;
  }

  /// Worker args as the app builds them: `force: true` is the run gate every
  /// real sync passes; [fullResync] is the separate explicit flag.
  Future<void> sync(Collection collection, {bool fullResync = false}) async {
    final port = ReceivePort();
    final queue = SequentialWriteQueue();
    port.listen((m) => tryHandleScanWrite(m, queue));
    try {
      await ImapScannerIsolateWorker.execute({
        'token': null,
        'port': port.sendPort,
        'collection': collection,
        'folderId': null,
        'force': true,
        'fullResync': fullResync,
        'appDir': tempDir.path,
        'dbDir': manager.databaseDirectoryPath!,
        'vaultDek': null,
      });
    } finally {
      port.close();
    }
  }

  Future<List<Map<String, Object?>>> emails() => manager.database!.select(
    'SELECT id, uid, subject, folder_id, labels, is_read, is_deleted, '
    'message_id FROM emails ORDER BY message_id',
  );

  Future<Map<String, Object?>> byMessageId(String mid) async =>
      (await emails()).singleWhere((e) => e['message_id'] == mid);

  Future<Map<String, Object?>> folderState(String id) async =>
      (await manager.database!.select(
        'SELECT * FROM email_folders WHERE id = ?',
        [id],
      )).single;

  SeedMessage msg(String n, {List<String>? flags, String? id}) => SeedMessage(
    messageId: id ?? '<incr-$n@test.local>',
    subject: 'Subject $n',
    date: DateTime.utc(2026, 1, 1, 10),
    flags: flags,
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

  imapTest(
    'initial sync covers every selectable folder and stores sync state',
    () async {
      final c = await persisted(EmailDeletePolicy.keep);
      final inbox = await seedMessages(seeder!, 'INBOX', [
        msg('i1'),
        msg('i2'),
      ]);
      await seedMessages(seeder!, 'Sent', [msg('s1')]);
      await seedMessages(seeder!, 'Trash', [msg('t1')]);

      await sync(c);

      final rows = await emails();
      expect(rows.map((e) => '${e['folder_id']}:${e['subject']}').toSet(), {
        'INBOX:Subject i1',
        'INBOX:Subject i2',
        'Sent:Subject s1',
        'Trash:Subject t1',
      });
      final st = await folderState('INBOX');
      expect(st['uid_validity'], isNotNull);
      expect(st['last_synced_uid'], inbox.last);
      expect(st['uid_next'], isNotNull);
      expect(st['highest_modseq'], isNotNull, reason: 'CONDSTORE is enabled');
      final types = {
        for (final f in await manager.database!.select(
          'SELECT id, type FROM email_folders',
        ))
          f['id']: f['type'],
      };
      expect(types['Sent'], 'sent');
      expect(types['Trash'], 'trash');
      expect(types['INBOX'], 'inbox');
    },
  );

  imapTest(
    'second sync fetches only new UIDs and skips unchanged folders',
    () async {
      final c = await persisted(EmailDeletePolicy.keep);
      await seedMessages(seeder!, 'INBOX', [msg('a'), msg('b')]);
      await sync(c);
      // A re-fetch would upsert over this; an incremental sync must not.
      await manager.database!.execute(
        "UPDATE emails SET subject = 'LOCAL EDIT' WHERE message_id = '<incr-a@test.local>'",
      );

      final newUid = (await seedMessages(seeder!, 'INBOX', [msg('c')])).single;
      await sync(c);

      final rows = await emails();
      expect(rows, hasLength(3));
      expect(
        (await byMessageId('<incr-a@test.local>'))['subject'],
        'LOCAL EDIT',
      );
      expect((await byMessageId('<incr-c@test.local>'))['uid'], newUid);
      expect((await folderState('INBOX'))['last_synced_uid'], newUid);

      // Nothing changed: still no churn and no duplicates.
      await sync(c);
      expect(await emails(), hasLength(3));
    },
  );

  imapTest(
    'the app path (force: true, no fullResync) is incremental, not a reset',
    () async {
      final c = await persisted(EmailDeletePolicy.keep);
      await seedMessages(seeder!, 'INBOX', [msg('g1'), msg('g2')]);
      await sync(c);
      final before = await folderState('INBOX');
      // Local edits survive only if nothing is re-fetched or re-matched.
      await manager.database!.execute(
        "UPDATE emails SET subject = 'LOCAL EDIT', is_read = 1",
      );

      final newUid = (await seedMessages(seeder!, 'INBOX', [msg('g3')])).single;
      await sync(c);

      final rows = await emails();
      expect(rows, hasLength(3), reason: 'no duplicate inserts');
      expect(
        rows.where((e) => e['subject'] == 'LOCAL EDIT'),
        hasLength(2),
        reason: 'old messages were not re-fetched',
      );
      expect((await byMessageId('<incr-g3@test.local>'))['uid'], newUid);
      final after = await folderState('INBOX');
      expect(after['uid_validity'], before['uid_validity']);
      expect(after['last_synced_uid'], newUid);
    },
  );

  imapTest('flag changes arrive via CONDSTORE CHANGEDSINCE', () async {
    final c = await persisted(EmailDeletePolicy.keep);
    final uids = await seedMessages(seeder!, 'INBOX', [
      msg('r1'),
      msg('r2', flags: [r'\Seen']),
    ]);
    await sync(c);
    expect((await byMessageId('<incr-r1@test.local>'))['is_read'], 0);
    expect((await byMessageId('<incr-r2@test.local>'))['is_read'], 1);

    await seeder!.selectMailboxByPath('INBOX');
    await seeder!.uidMarkSeen(MessageSequence.fromIds([uids[0]], isUid: true));
    await seeder!.uidMarkUnseen(
      MessageSequence.fromIds([uids[1]], isUid: true),
    );
    await sync(c);

    expect((await byMessageId('<incr-r1@test.local>'))['is_read'], 1);
    expect((await byMessageId('<incr-r2@test.local>'))['is_read'], 0);
  });

  for (final policy in EmailDeletePolicy.values) {
    imapTest('server-side expunge under policy ${policy.dbValue}', () async {
      final c = await persisted(policy);
      final uids = await seedMessages(seeder!, 'INBOX', [msg('x1'), msg('x2')]);
      await sync(c);
      await expungeUids(seeder!, 'INBOX', [uids[0]]);

      await sync(c);

      final rows = await emails();
      switch (policy) {
        case EmailDeletePolicy.keep:
          expect(rows, hasLength(2));
          expect((await byMessageId('<incr-x1@test.local>'))['is_deleted'], 0);
        case EmailDeletePolicy.markDeleted:
          expect(rows, hasLength(2));
          expect((await byMessageId('<incr-x1@test.local>'))['is_deleted'], 1);
        case EmailDeletePolicy.remove:
          expect(rows.map((e) => e['message_id']), ['<incr-x2@test.local>']);
      }
      expect((await byMessageId('<incr-x2@test.local>'))['is_deleted'], 0);
    });
  }

  group('same Message-ID in several folders', () {
    const mid = '<incr-dup@test.local>';

    Future<({int inboxUid, int archiveUid})> seedDup() async {
      final i =
          (await seedMessages(seeder!, 'INBOX', [msg('dup', id: mid)])).single;
      final a =
          (await seedMessages(seeder!, 'Archive', [
            msg('dup', id: mid),
          ])).single;
      return (inboxUid: i, archiveUid: a);
    }

    imapTest(
      'is one email row, with the second folder recorded in labels',
      () async {
        final c = await persisted(EmailDeletePolicy.markDeleted);
        final uids = await seedDup();

        await sync(c);

        final row = await byMessageId(mid);
        expect((await emails()), hasLength(1));
        expect(row['folder_id'], 'INBOX');
        expect(row['uid'], uids.inboxUid);
        expect(row['labels'], 'Archive');
        // The folder filter must find it in both folders.
        final inArchive = await manager.database!.select(
          "SELECT id FROM emails WHERE instr(',' || labels || ',', ',Archive,') > 0",
        );
        expect(inArchive, hasLength(1));
      },
    );

    imapTest('expunged from its primary folder only: not deleted or hidden, '
        'the other copy becomes primary', () async {
      final c = await persisted(EmailDeletePolicy.remove);
      final uids = await seedDup();
      await sync(c);
      await expungeUids(seeder!, 'INBOX', [uids.inboxUid]);

      await sync(c);

      final row = await byMessageId(mid);
      expect(row['is_deleted'], 0);
      expect(row['folder_id'], 'Archive');
      expect(row['uid'], uids.archiveUid);
      expect(row['labels'], '');
    });

    imapTest(
      'expunged from a secondary folder only: stays, membership dropped',
      () async {
        final c = await persisted(EmailDeletePolicy.markDeleted);
        final uids = await seedDup();
        await sync(c);
        await expungeUids(seeder!, 'Archive', [uids.archiveUid]);

        await sync(c);

        final row = await byMessageId(mid);
        expect(row['is_deleted'], 0);
        expect(row['folder_id'], 'INBOX');
        expect(row['labels'], '');
      },
    );

    imapTest(
      'gone from every folder: the delete policy finally applies',
      () async {
        final c = await persisted(EmailDeletePolicy.markDeleted);
        final uids = await seedDup();
        await sync(c);
        await expungeUids(seeder!, 'INBOX', [uids.inboxUid]);
        await sync(c);
        await expungeUids(seeder!, 'Archive', [uids.archiveUid]);

        await sync(c);

        expect((await byMessageId(mid))['is_deleted'], 1);
      },
    );

    imapTest('messages without a Message-ID are never deduped', () async {
      final c = await persisted(EmailDeletePolicy.keep);
      for (final box in ['INBOX', 'Archive']) {
        await seeder!.appendMessageText(
          'Date: Thu, 01 Jan 2026 10:00:00 +0000\r\nFrom: a@example.com\r\n'
          'To: alice@test.local\r\nSubject: anon\r\n\r\nbody\r\n',
          targetMailboxPath: box,
        );
      }
      await sync(c);
      expect(await emails(), hasLength(2));
    });
  });

  imapTest(
    'UIDVALIDITY change re-matches by Message-ID and keeps archive mail',
    () async {
      final c = await persisted(EmailDeletePolicy.keep);
      await seeder!.createMailbox(scratchMailbox);
      final first = await seedMessages(seeder!, scratchMailbox, [
        msg('v1', id: '<incr-v1@test.local>'),
        msg('v2', id: '<incr-v2@test.local>'),
      ]);
      await sync(c);
      final oldValidity = (await folderState(scratchMailbox))['uid_validity'];
      expect(oldValidity, isNotNull);

      // Recreate the mailbox: new UIDVALIDITY, and UIDs restart. Dovecot derives
      // the validity from the creation time, so wait out the second boundary.
      await _dropMailbox(seeder!, scratchMailbox);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await seeder!.createMailbox(scratchMailbox);
      // Push UIDs so they clash with the OLD numbering of a different message.
      final second = await seedMessages(seeder!, scratchMailbox, [
        msg('v3', id: '<incr-v3@test.local>'),
        msg('v1', id: '<incr-v1@test.local>'),
      ]);
      final newValidity =
          (await seeder!.selectMailboxByPath(scratchMailbox)).uidValidity;
      expect(
        newValidity,
        isNot(oldValidity),
        reason: 'the test must really change UIDVALIDITY',
      );

      await sync(c);

      final rows = await emails();
      expect(rows.map((e) => e['message_id']).toSet(), {
        '<incr-v1@test.local>',
        '<incr-v2@test.local>', // gone from server but kept: policy keep
        '<incr-v3@test.local>',
      });
      expect(
        rows,
        hasLength(3),
        reason: 'v1 must be re-matched, not duplicated',
      );
      final v1 = await byMessageId('<incr-v1@test.local>');
      expect(v1['uid'], second[1]);
      expect(v1['uid'], isNot(first[0]));
      expect((await byMessageId('<incr-v2@test.local>'))['is_deleted'], 0);
      expect((await folderState(scratchMailbox))['uid_validity'], newValidity);
    },
  );

  imapTest(
    'UIDVALIDITY change then the message is gone: policy applies',
    () async {
      final c = await persisted(EmailDeletePolicy.markDeleted);
      await seeder!.createMailbox(scratchMailbox);
      await seedMessages(seeder!, scratchMailbox, [msg('w1'), msg('w2')]);
      await sync(c);
      await _dropMailbox(seeder!, scratchMailbox);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await seeder!.createMailbox(scratchMailbox);
      await seedMessages(seeder!, scratchMailbox, [msg('w2')]);

      await sync(c);

      expect((await byMessageId('<incr-w1@test.local>'))['is_deleted'], 1);
      expect((await byMessageId('<incr-w2@test.local>'))['is_deleted'], 0);
    },
  );

  imapTest('fullResync ignores stored sync state and resyncs', () async {
    final c = await persisted(EmailDeletePolicy.keep);
    await seedMessages(seeder!, 'INBOX', [msg('f1')]);
    await sync(c);
    // Corrupt the watermark so an incremental sync would miss new mail.
    await manager.database!.execute(
      "UPDATE email_folders SET last_synced_uid = 99999, uid_next = NULL "
      "WHERE id = 'INBOX'",
    );
    await seedMessages(seeder!, 'INBOX', [msg('f2')]);

    await sync(c);
    expect(
      await emails(),
      hasLength(1),
      reason: 'incremental trusts the watermark',
    );

    await sync(c, fullResync: true);
    expect(await emails(), hasLength(2));
    expect(
      await emails().then((r) => r.map((e) => e['uid']).toSet()),
      hasLength(2),
    );
  });

  imapTest('authentication failure marks the scan as error', () async {
    final c = await persisted(EmailDeletePolicy.keep);
    c.accessToken = 'wrong';
    await seedMessages(seeder!, 'INBOX', [msg('e1')]);

    await sync(c);

    final status = await manager.database!.select(
      'SELECT scan_status FROM collections WHERE id = ?',
      [c.id],
    );
    expect(status.single['scan_status'], 'error');
    expect(await emails(), isEmpty);
  });
}

Future<void> _dropMailbox(ImapClient client, String path) async {
  try {
    await client.selectInbox();
    await client.deleteMailbox(
      Mailbox(
        encodedName: path,
        encodedPath: path,
        pathSeparator: "/",
        flags: [],
      ),
    );
  } catch (_) {}
}
