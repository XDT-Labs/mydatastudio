import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/services/scan_write_relay.dart';

/// The cloud scanner's file batches must reach the upsert that drops a stale
/// local copy; the generic `batchFile` write deliberately keeps local_path.
void main() {
  late Directory tempDir;
  late DatabaseManager manager;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('scan_relay_cloud_');
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

  File row(DateTime modified) => File(
    id: 'c1:x',
    collectionId: 'c1',
    name: 'x.pdf',
    path: 'fake://x',
    parent: '',
    dateCreated: DateTime.utc(2024),
    dateLastModified: modified,
    isDeleted: false,
    size: 1,
    contentType: 'application/pdf',
  );

  Future<String?> localPath() async =>
      (await manager.database!.select(
            'SELECT local_path FROM files WHERE id = ?',
            ['c1:x'],
          )).single['local_path']
          as String?;

  test('cloudFileBatch clears the local copy of a changed file', () async {
    await handleScanWriteMessage({
      'service': 'cloudFileBatch',
      'payload': [row(DateTime.utc(2024))],
    });
    await manager.database!.execute(
      "UPDATE files SET local_path = '/archive/x.pdf' WHERE id = 'c1:x'",
    );

    await handleScanWriteMessage({
      'service': 'cloudFileBatch',
      'payload': [row(DateTime.utc(2025))],
    });

    expect(await localPath(), isNull);
  });
}
