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

import '../helpers/imap_test_server.dart';

/// Deleting a message moves it to the server's trash, and tells the caller
/// whether it did: the app deletes its own copy only on a confirmed move.
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
    tempDir = await Directory.systemTemp.createTemp('imap_del_it_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((_) async => tempDir.path);
    manager = DatabaseManager.instance;
    await manager.initializeDatabase();
    seeder = await connectImapTestClient(user: imapTestUserBob);
    for (final m in ['INBOX', 'Archive', 'Trash', 'Papierkorb']) {
      await deleteAll(seeder!, m);
    }
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

  Collection account() => Collection(
    id: 'imap-del',
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

  SeedMessage msg(String id) => SeedMessage(
    messageId: '<$id@test.local>',
    subject: 'Subject $id',
    date: DateTime.utc(2026, 1, 1, 10),
  );

  Future<bool> move(
    Collection collection,
    String folder,
    List<int> uids, {
    Map<String, List<String>> otherCopies = const {},
  }) async {
    final result = ReceivePort();
    final messages = <Object?>[];
    final sub = result.listen(messages.add);
    await ImapScannerIsolateWorker.execute({
      'token': null,
      'collection': collection,
      'folderId': folder,
      'uids': uids,
      'otherCopies': otherCopies,
      'resultPort': result.sendPort,
      'type': 'move_to_trash',
      'appDir': tempDir.path,
      'dbDir': manager.databaseDirectoryPath!,
      'vaultDek': null,
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    result.close();
    return messages.contains(true);
  }

  Future<int> count(String mailbox) async {
    final box = await seeder!.selectMailboxByPath(mailbox);
    return box.messagesExists;
  }

  // The test server flags two folders as trash (Trash and Papierkorb).
  Future<int> trashCount() async =>
      await count('Trash') + await count('Papierkorb');

  void imapTest(String name, Future<void> Function() body) {
    test(name, () async {
      if (!available) {
        markTestSkipped('IMAP test server not reachable');
        return;
      }
      await body();
    });
  }

  imapTest('a confirmed move puts the message in Trash', () async {
    final uids = await seedMessages(seeder!, 'INBOX', [msg('m1'), msg('m2')]);

    expect(await move(account(), 'INBOX', [uids.first]), isTrue);

    expect(await count('INBOX'), 1);
    expect(await trashCount(), 1);
  });

  imapTest('copies in other folders go to Trash too', () async {
    // Left behind, a copy would be re-added by Message-ID on the next sync.
    final uids = await seedMessages(seeder!, 'INBOX', [msg('m3')]);
    await seedMessages(seeder!, 'Archive', [msg('m3'), msg('m4')]);

    final moved = await move(
      account(),
      'INBOX',
      uids,
      otherCopies: {
        'Archive': ['<m3@test.local>'],
      },
    );

    expect(moved, isTrue);
    expect(await count('INBOX'), 0);
    expect(await count('Archive'), 1, reason: 'the unrelated message stays');
    expect(await trashCount(), 2);
  });

  imapTest('a failed move is reported, not assumed', () async {
    final uids = await seedMessages(seeder!, 'INBOX', [msg('m5')]);

    final moved = await move(account(), 'NoSuchFolder', uids);

    expect(moved, isFalse);
    expect(await count('INBOX'), 1);
  });
}
