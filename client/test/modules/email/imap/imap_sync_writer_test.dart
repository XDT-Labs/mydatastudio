import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/services/email_folder_repository.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_sync_writer.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

import '../../../helpers/email_fixture.dart';

void main() {
  late Directory tempDir;
  late DatabaseManager manager;
  late ImapSyncWriter writer;

  Collection collection(EmailDeletePolicy policy) => Collection(
    id: 'c1',
    name: 'acct',
    path: 'acct',
    type: 'email',
    scanner: 'email.imap',
    scanStatus: 'idle',
    needsReAuth: false,
    emailDeletePolicy: policy,
  );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('imap_writer_test_');
    // ignore: deprecated_member_use
    const MethodChannel('plugins.flutter.io/path_provider')
    // ignore: deprecated_member_use
    .setMockMethodCallHandler((_) async => tempDir.path);
    manager = DatabaseManager.instance;
    await manager.initializeDatabase();
    writer = ImapSyncWriter(manager.database!);
    await CollectionRepository(
      manager.database!,
    ).addCollection(collection(EmailDeletePolicy.keep));
    await EmailFolderRepository(manager.database!).upsertFolder(
      EmailFolder(
        id: 'INBOX',
        collectionId: 'c1',
        name: 'INBOX',
        uidValidity: 7,
        uidNext: 9,
        highestModseq: 4,
        lastSyncedUid: 8,
      ),
    );
    await EmailRepository(manager.database!).addEmails([
      makeTestEmail(
        id: 'e1',
        collectionId: 'c1',
        folderId: 'INBOX',
        uid: 1,
        messageId: '<1>',
      ),
      makeTestEmail(
        id: 'e2',
        collectionId: 'c1',
        folderId: 'INBOX',
        uid: 2,
        messageId: '<2>',
      ),
    ]);
  });

  tearDown(() {
    manager.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, Object?>> row(String id) async =>
      (await manager.database!.select('SELECT * FROM emails WHERE id = ?', [
        id,
      ])).single;

  test('resetFolder clears sync state AND uids, keeping the mail', () async {
    await writer.resetFolder('c1', 'INBOX');
    final f =
        (await EmailFolderRepository(
          manager.database!,
        ).byCollectionId('c1')).single;
    expect(
      [f.uidValidity, f.uidNext, f.highestModseq, f.lastSyncedUid],
      [null, null, null, null],
    );
    expect((await row('e1'))['uid'], isNull);
    expect((await row('e1'))['is_deleted'], 0);
  });

  test('saveFolderState can set values and later null them', () async {
    await writer.saveFolderState(
      'c1',
      'INBOX',
      uidValidity: 9,
      lastSyncedUid: 3,
    );
    final f =
        (await EmailFolderRepository(
          manager.database!,
        ).byCollectionId('c1')).single;
    expect(
      [f.uidValidity, f.uidNext, f.highestModseq, f.lastSyncedUid],
      [9, null, null, 3],
    );
  });

  group('applyDeletePolicy', () {
    test('keep leaves the row visible and untouched', () async {
      await writer.applyDeletePolicy(collection(EmailDeletePolicy.keep), [
        'e1',
      ]);
      expect((await row('e1'))['is_deleted'], 0);
    });

    test('markDeleted hides the row but keeps it', () async {
      await writer.applyDeletePolicy(
        collection(EmailDeletePolicy.markDeleted),
        ['e1'],
      );
      expect((await row('e1'))['is_deleted'], 1);
      expect((await row('e2'))['is_deleted'], 0);
    });

    test('remove deletes the row', () async {
      await writer.applyDeletePolicy(collection(EmailDeletePolicy.remove), [
        'e1',
      ]);
      final rows = await manager.database!.select(
        'SELECT id FROM emails WHERE id = ?',
        ['e1'],
      );
      expect(rows, isEmpty);
      expect((await row('e2'))['id'], 'e2');
    });
  });

  test(
    'addMembership puts the folder in labels once, never for the primary',
    () async {
      await writer.addMembership('c1', 'Archive', ['e1']);
      await writer.addMembership('c1', 'Archive', ['e1']);
      await writer.addMembership('c1', 'INBOX', ['e1']);
      expect((await row('e1'))['labels'], 'Archive');
    },
  );

  test('dropMembership removes only that folder', () async {
    await writer.addMembership('c1', 'A', ['e1']);
    await writer.addMembership('c1', 'B', ['e1']);
    await writer.dropMembership('c1', 'A', ['e1']);
    expect((await row('e1'))['labels'], 'B');
  });

  test('promote makes a secondary copy the primary', () async {
    await writer.addMembership('c1', 'Archive', ['e1']);
    await writer.promote('c1', [
      (id: 'e1', folderId: 'Archive', uid: 77, labels: <String>[]),
    ]);
    final r = await row('e1');
    expect([r['folder_id'], r['uid'], r['labels']], ['Archive', 77, '']);
  });

  test('setRead only touches the matching folder and uid', () async {
    await writer.setRead('c1', 'INBOX', {2: true});
    expect((await row('e1'))['is_read'], 0);
    expect((await row('e2'))['is_read'], 1);
  });

  test('rematch assigns the new uid', () async {
    await writer.resetFolder('c1', 'INBOX');
    await writer.rematch('c1', 'INBOX', [(id: 'e1', uid: 40, isRead: true)]);
    final r = await row('e1');
    expect([r['uid'], r['is_read']], [40, 1]);
  });

  // Gmail moves a message between labels without changing its UID; the label
  // columns must follow, and a later label-only change must not lose the
  // thread.
  test('setGmailMeta replaces labels and sets the thread', () async {
    await writer.addMembership('c1', 'Old', ['e1']);
    await writer.setGmailMeta('c1', 'INBOX', [
      (uid: 1, labels: ['INBOX', 'Work'], threadId: '99'),
    ]);
    var r = await row('e1');
    expect([r['labels'], r['thread_id']], ['INBOX,Work', '99']);

    await writer.setGmailMeta('c1', 'INBOX', [
      (uid: 1, labels: <String>[], threadId: null),
    ]);
    r = await row('e1');
    expect([r['labels'], r['thread_id']], ['', '99']);
    expect((await row('e2'))['labels'], '');
  });
}
