import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/scan_write_relay.dart';

void main() {
  late Directory tempDir;
  late DatabaseManager manager;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('scan_relay_status_');
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

  Future<void> add(String id, DateTime? lastScan) =>
      CollectionRepository(manager.database!).addCollection(
        Collection(
          id: id,
          name: id,
          path: id,
          type: 'email',
          scanner: 'email.imap',
          scanStatus: 'scanning',
          needsReAuth: false,
          lastScanDate: lastScan,
        ),
      );

  Future<Map<String, Object?>> row(String id) async => (await manager.database!
      .select('SELECT scan_status, last_scan_date FROM collections WHERE id = ?', [id]))
      .single;

  Future<void> send(String id, DateTime? date) => handleScanWriteMessage({
    'service': 'collectionStatus',
    'payload': {'collectionId': id, 'scanStatus': 'error', 'lastScanDate': date},
  });

  test('a null date sets the status and leaves an existing last_scan_date', () async {
    final when = DateTime.utc(2026, 3, 4, 5, 6, 7);
    await add('has-date', when);
    await send('has-date', null);
    final r = await row('has-date');
    expect(r['scan_status'], 'error');
    expect(r['last_scan_date'], when.millisecondsSinceEpoch);
  });

  test('a null date keeps a never-scanned collection NULL', () async {
    await add('never', null);
    await send('never', null);
    final r = await row('never');
    expect(r['scan_status'], 'error');
    expect(r['last_scan_date'], isNull);
  });

  test('a non-null date is still written', () async {
    await add('c', null);
    final when = DateTime.utc(2026, 5, 6);
    await send('c', when);
    expect((await row('c'))['last_scan_date'], when.millisecondsSinceEpoch);
  });
}
