import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/file_sources/sync_folder/online_only_checker.dart';
import 'package:mydatastudio/modules/files/services/scanners/local_file_isolate.dart';
import 'package:path/path.dart' as p;

/// Legacy iCloud Drive leaves `.name.ext.icloud` stubs for online-only files.
/// The user must see `name.ext`, and nothing may read the (absent) content.
void main() {
  late io.Directory root;
  late LocalFileIsolateWorker worker;
  late ReceivePort port;

  setUp(() {
    root = io.Directory.systemTemp.createTempSync('icloud_stub');
    port = ReceivePort();
    worker = LocalFileIsolateWorker(
      null,
      port.sendPort,
      root.path,
      'test.db',
      port.sendPort,
    );
  });
  tearDown(() {
    port.close();
    root.deleteSync(recursive: true);
  });

  io.File touch(String name) =>
      io.File(p.join(root.path, name))..writeAsStringSync('stub');

  test('a stub is listed under its real name and path, unhashed', () async {
    final r = await worker.validateFileForTest(
      'c1',
      touch('.report.pdf.icloud'),
      root.path,
    );
    final file = r['file'];
    expect(file, isNotNull, reason: 'stubs are hidden files but must be kept');
    expect(file.name, 'report.pdf');
    expect(file.path, 'report.pdf');
    expect(file.contentHash, isNull, reason: 'hashing would download it');
  });

  test('an ordinary hidden file is still skipped', () async {
    final r = await worker.validateFileForTest(
      'c1',
      touch('.DS_Store'),
      root.path,
    );
    expect(r['file'], isNull);
  });

  test('a dataless image is not read for EXIF or a thumbnail', () async {
    // An `SF_DATALESS` file keeps its normal name, so only the checker knows
    // it is online-only; opening it would make macOS download it.
    final dataless = LocalFileIsolateWorker(
      null,
      port.sendPort,
      root.path,
      'test.db',
      port.sendPort,
      onlineOnlyChecker: _AllOnlineOnly(),
    );
    final r = await dataless.validateFileForTest(
      'c1',
      touch('photo.jpg'),
      root.path,
    );
    expect(r['file'], isNotNull);
    expect(r['contentReadable'], isFalse);
    expect(r['file'].contentHash, isNull);
  });

  test('a dataless file is stored as online-only', () async {
    // The embedding queues read every file they are handed, and reading a
    // dataless file downloads it. The row flag is what keeps it out of them.
    final dataless = LocalFileIsolateWorker(
      null,
      port.sendPort,
      root.path,
      'test.db',
      port.sendPort,
      onlineOnlyChecker: _AllOnlineOnly(),
    );
    final f = touch('notes.pdf');
    final first = await dataless.validateFileForTest('c1', f, root.path);
    expect(first['file'].isOnlineOnly, isTrue);

    // An unchanged file rescans through the cache-hit path, which builds its
    // own row: it must carry the current state too, or a file evicted after
    // its first scan would never be flagged.
    final cached = first['file'] as File;
    final again = await dataless.validateFileForTest(
      'c1',
      f,
      root.path,
      metadataCache: {cached.id: cached..isOnlineOnly = false},
    );
    expect(again['isCacheHit'], isTrue);
    expect(again['file'].isOnlineOnly, isTrue);
  });

  test(
    'a file that is on disk is not online-only, even from the cache',
    () async {
      final f = touch('notes.pdf');
      final first = await worker.validateFileForTest('c1', f, root.path);
      expect(first['file'].isOnlineOnly, isFalse);
      // Downloaded since the last scan: the cached row still says online-only.
      final cached = (first['file'] as File)..isOnlineOnly = true;
      final again = await worker.validateFileForTest(
        'c1',
        f,
        root.path,
        metadataCache: {cached.id: cached},
      );
      expect(again['file'].isOnlineOnly, isFalse);
    },
  );

  test('a local image stays readable', () async {
    final r = await worker.validateFileForTest(
      'c1',
      touch('photo.jpg'),
      root.path,
    );
    expect(r['contentReadable'], isTrue);
  });
}

class _AllOnlineOnly implements OnlineOnlyChecker {
  @override
  bool isOnlineOnly(String path) => true;
}
