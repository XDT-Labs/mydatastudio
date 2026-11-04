@Tags(['imap'])
library;

import 'dart:io';
import 'dart:isolate';

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

/// A rejected login must be reported on the collection, and flagged for
/// re-auth, rather than looking like a healthy idle account.
void main() {
  late bool available;
  late Directory tempDir;
  late DatabaseManager manager;

  setUpAll(() async {
    available = await isImapTestServerAvailable();
  });

  setUp(() async {
    if (!available) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('imap_auth_it_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((_) async => tempDir.path);
    manager = DatabaseManager.instance;
    await manager.initializeDatabase();
  });

  tearDown(() async {
    if (!available) return;
    manager.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('wrong password sets scan_status=error and needs_re_auth', () async {
    if (!available) {
      markTestSkipped('IMAP test server not running (make imap-test-up)');
      return;
    }
    final collection = Collection(
      id: 'imap-auth-it',
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
    );
    await CollectionRepository(manager.database!).addCollection(collection);
    collection.accessToken = 'definitely-the-wrong-password';

    final port = ReceivePort();
    final queue = SequentialWriteQueue();
    port.listen((m) => tryHandleScanWrite(m, queue));
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
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } finally {
      port.close();
    }

    final stored =
        (await CollectionRepository(manager.database!).collectionById(
          'imap-auth-it',
        ))!;
    expect(stored.scanStatus, 'error');
    expect(stored.needsReAuth, isTrue);
  }, tags: 'imap');
}
