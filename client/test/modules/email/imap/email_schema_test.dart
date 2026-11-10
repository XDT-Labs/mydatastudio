import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/services/email_folder_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

const _collectionCols = [
  'email_provider_id',
  'imap_settings',
  'email_delete_policy',
];
const _folderCols = [
  'path',
  'uid_validity',
  'uid_next',
  'highest_modseq',
  'last_synced_uid',
];

void main() {
  late Directory tempDir;
  late DatabaseManager manager;

  Future<Set<String>> columns(String table) async => (await manager.database!
          .select('PRAGMA table_info($table)'))
      .map((r) => r['name'] as String)
      .toSet();

  Future<bool> hasMessageIdIndex() async => (await manager.database!.select(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND tbl_name='emails' AND name='email_message_id_idx'",
      )).isNotEmpty;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('email_schema_test_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((_) async => tempDir.path);
    manager = DatabaseManager.instance;
    await manager.initializeDatabase();
  });

  tearDown(() {
    manager.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('fresh DB has the new columns and index', () async {
    expect(await columns('collections'), containsAll(_collectionCols));
    expect(await columns('email_folders'), containsAll(_folderCols));
    expect(await hasMessageIdIndex(), isTrue);
  });

  test('a DB created before this change is migrated on open', () async {
    final db = manager.database!;
    for (final c in _collectionCols) {
      await db.execute('ALTER TABLE collections DROP COLUMN $c');
    }
    for (final c in _folderCols) {
      await db.execute('ALTER TABLE email_folders DROP COLUMN $c');
    }
    await db.execute('DROP INDEX email_message_id_idx');
    expect(await columns('collections'), isNot(contains('imap_settings')));

    manager.dispose();
    await manager.initializeDatabase();

    expect(await columns('collections'), containsAll(_collectionCols));
    expect(await columns('email_folders'), containsAll(_folderCols));
    expect(await hasMessageIdIndex(), isTrue);
  });

  test('Collection round-trips the IMAP fields; default policy is keep', () async {
    final repo = CollectionRepository(manager.database!);
    await repo.addCollection(
      Collection(
        id: 'plain',
        name: 'n',
        path: 'plain@x.org',
        type: 'email',
        scanner: 'email.yahoo',
        scanStatus: 'idle',
        needsReAuth: false,
      ),
    );
    await repo.addCollection(
      Collection(
        id: 'imap',
        name: 'n',
        path: 'imap@x.org',
        type: 'email',
        scanner: 'email.imap',
        scanStatus: 'idle',
        needsReAuth: false,
        emailProviderId: 'other',
        imapSettings: '{"host":"h"}',
        emailDeletePolicy: EmailDeletePolicy.markDeleted,
      ),
    );
    final all = {for (final c in await repo.collections()) c.id: c};
    expect(all['plain']!.emailDeletePolicy, EmailDeletePolicy.keep);
    expect(all['plain']!.emailProviderId, isNull);
    expect(all['imap']!.emailProviderId, 'other');
    expect(all['imap']!.imapSettings, '{"host":"h"}');
    expect(all['imap']!.emailDeletePolicy, EmailDeletePolicy.markDeleted);

    final updated = all['imap']!..emailDeletePolicy = EmailDeletePolicy.remove;
    await repo.updateCollection(updated);
    final again = (await repo.collections()).firstWhere((c) => c.id == 'imap');
    expect(again.emailDeletePolicy, EmailDeletePolicy.remove);
  });

  test('EmailDeletePolicy maps unknown strings to keep', () {
    for (final p in EmailDeletePolicy.values) {
      expect(EmailDeletePolicy.fromDb(p.dbValue), p);
    }
    expect(EmailDeletePolicy.fromDb('garbage'), EmailDeletePolicy.keep);
    expect(EmailDeletePolicy.fromDb(null), EmailDeletePolicy.keep);
  });

  test('refreshing the folder list keeps IMAP sync state', () async {
    await CollectionRepository(manager.database!).addCollection(
      Collection(
        id: 'c',
        name: 'n',
        path: 'p',
        type: 'email',
        scanner: 'email.yahoo',
        scanStatus: 'idle',
        needsReAuth: false,
      ),
    );
    final repo = EmailFolderRepository(manager.database!);
    await repo.upsertFolder(
      EmailFolder(
        id: 'INBOX',
        collectionId: 'c',
        name: 'INBOX',
        path: 'INBOX',
        uidValidity: 7,
        uidNext: 100,
        highestModseq: 55,
        lastSyncedUid: 99,
      ),
    );
    // A later listing pass knows nothing about sync state.
    await repo.upsertFolder(
      EmailFolder(id: 'INBOX', collectionId: 'c', name: 'Inbox', type: 'inbox'),
    );
    final f = (await repo.byCollectionId('c')).single;
    expect(f.name, 'Inbox');
    expect(f.type, 'inbox');
    expect(f.path, 'INBOX');
    expect(f.uidValidity, 7);
    expect(f.uidNext, 100);
    expect(f.highestModseq, 55);
    expect(f.lastSyncedUid, 99);
  });
}
