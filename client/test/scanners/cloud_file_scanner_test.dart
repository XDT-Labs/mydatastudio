import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_scanner.dart';
import 'package:path/path.dart' as p;

class _MockDb extends Mock implements AppDatabase {}

/// In-memory drive: folderId -> children. Pages hold [pageSize] entries.
class FakeCloudFileApi implements CloudFileApi {
  final Map<String, List<CloudFileEntry>> tree;
  final int pageSize;
  final List<String> listedFolders = [];
  final List<String> downloaded = [];
  final List<CloudFileEntry> changed;
  int changedCalls = 0;
  int failDownloadsLeft = 0;

  FakeCloudFileApi(this.tree, {this.pageSize = 1000, this.changed = const []});

  @override
  String get scheme => 'fake';

  @override
  Future<CloudFilePage> listChildren(
    String folderId, {
    String? pageToken,
  }) async {
    if (pageToken == null) listedFolders.add(folderId);
    final all = tree[folderId] ?? const [];
    final start = int.parse(pageToken ?? '0');
    final end = (start + pageSize).clamp(0, all.length);
    return CloudFilePage(
      all.sublist(start, end),
      nextPageToken: end < all.length ? '$end' : null,
    );
  }

  @override
  Future<CloudFilePage> listChangedSince(
    DateTime since, {
    String? pageToken,
  }) async {
    changedCalls++;
    return CloudFilePage(changed);
  }

  @override
  Future<CloudFileEntry?> getEntry(String id) async => null;

  @override
  bool isDownloadableMimeType(String mimeType) =>
      !mimeType.startsWith('application/x-native');

  @override
  Future<void> download(String id, String destPath) async {
    downloaded.add(id);
    if (failDownloadsLeft > 0) {
      failDownloadsLeft--;
      await io.File(destPath).writeAsString('par');
      throw const FormatException('connection lost');
    }
    await io.File(destPath).writeAsString('bytes of $id');
  }
}

CloudFileEntry _file(String id, {String mime = 'text/plain'}) =>
    CloudFileEntry(id: id, name: '$id.txt', mimeType: mime, size: 5);
CloudFileEntry _folder(String id) =>
    CloudFileEntry(id: id, name: id, isFolder: true);

void main() {
  late ReceivePort port;
  late StreamSubscription<dynamic> sub;
  late List<Map> writes;
  late String tmp;
  String? failService;

  setUp(() {
    writes = [];
    failService = null;
    port = ReceivePort();
    // Stand-in for the main isolate: records each relayed write and acks it.
    sub = port.listen((m) {
      if (m is! Map || m['type'] != 'dbWrite') return;
      writes.add({'service': m['service'], 'payload': m['payload']});
      (m['replyTo'] as SendPort).send(
        m['service'] == failService
            ? {'ok': false, 'error': 'boom'}
            : {'ok': true, 'result': {}},
      );
    });
    tmp = io.Directory.systemTemp.createTempSync('cloud_scan_test').path;
  });

  tearDown(() async {
    await sub.cancel();
    port.close();
    io.Directory(tmp).deleteSync(recursive: true);
  });

  Map<String, dynamic> args({
    bool fullScan = true,
    bool force = true,
    bool recursive = true,
    bool download = false,
    String? lastScan,
    String root = 'root',
  }) => {
    'collectionId': 'c1',
    'collectionName': 'My Drive',
    'collectionPath': 'root',
    'rootFolderId': root,
    'isFullScan': fullScan,
    'force': force,
    'recursive': recursive,
    'downloadLocalCopy': download,
    'lastScanDate': lastScan,
    'appDir': tmp,
    'accessToken': 'a',
    'refreshToken': 'r',
  };

  CloudFileScannerWorker worker({List<File> toDownload = const []}) =>
      CloudFileScannerWorker(
        _MockDb(),
        null,
        port.sendPort,
        collectionExists: (_) async => true,
        filesToDownload: (_) async => toDownload,
      );

  Future<void> run(
    CloudFileScannerWorker w,
    CloudFileApi api,
    Map<String, dynamic> a,
  ) => w.scan(a, (_) async => api);

  Iterable<Map> of(String service) =>
      writes.where((w) => w['service'] == service);

  test('carries the provider sha256 onto the relayed file row', () async {
    final api = FakeCloudFileApi({
      'root': [
        const CloudFileEntry(id: 'h', name: 'h.txt', contentHash: 'abc123'),
      ],
    });
    await run(worker(), api, args());
    final files = of('batchFile').expand((w) => w['payload'] as List<File>);
    expect(files.single.contentHash, 'abc123');
  });

  test('walks folders breadth-first and writes folders and files', () async {
    final api = FakeCloudFileApi({
      'root': [_folder('a'), _file('f1')],
      'a': [_folder('b'), _file('f2')],
      'b': [_file('f3')],
    });
    await run(worker(), api, args());

    expect(api.listedFolders, ['root', 'a', 'b']);
    final folders = of('folder').map((w) => w['payload'] as Folder).toList();
    expect(folders.map((f) => f.path), ['a', 'b']);
    // Top-level folder has an empty parent (collection root); nested keeps id.
    expect(folders.map((f) => f.parent), ['', 'a']);
    final files = of('batchFile').expand((w) => w['payload'] as List<File>);
    expect(
      files.map((f) => f.path),
      unorderedEquals(['fake://f1', 'fake://f2', 'fake://f3']),
    );
    expect(files.first.id, startsWith('c1:'));
  });

  test('non-recursive scan lists only the requested folder', () async {
    final api = FakeCloudFileApi({
      'root': [_folder('a')],
      'a': [_file('f2')],
    });
    await run(
      worker(),
      api,
      args(recursive: false, fullScan: false, root: 'a'),
    );
    expect(api.listedFolders, ['a']);
  });

  test('follows page tokens', () async {
    final api = FakeCloudFileApi({
      'root': [for (var i = 0; i < 5; i++) _file('f$i')],
    }, pageSize: 2);
    await run(worker(), api, args());
    final files = of('batchFile').expand((w) => w['payload'] as List<File>);
    expect(files.length, 5);
  });

  test(
    'batches files in groups of 100, remainder flushed at the end',
    () async {
      final api = FakeCloudFileApi({
        'root': [for (var i = 0; i < 250; i++) _file('f$i')],
      });
      await run(worker(), api, args());
      expect(of('batchFile').map((w) => (w['payload'] as List).length), [
        100,
        100,
        50,
      ]);
    },
  );

  test(
    'full scan sweeps deleted files after writes; collection marked ready',
    () async {
      final api = FakeCloudFileApi({
        'root': [_file('f1')],
      });
      await run(worker(), api, args());
      final services = writes.map((w) => w['service']).toList();
      expect(services, [
        'batchFile',
        'cleanupDeletedFiles',
        'collectionStatus',
      ]);
      final cleanup = of('cleanupDeletedFiles').single['payload'] as Map;
      expect(cleanup['isCloud'], true);
      expect(cleanup['path'], '');
    },
  );

  test('incremental scan uses listChangedSince and never sweeps', () async {
    final api = FakeCloudFileApi({}, changed: [_file('f9')]);
    await run(
      worker(),
      api,
      args(force: false, lastScan: DateTime(2024).toIso8601String()),
    );
    expect(api.changedCalls, 1);
    expect(api.listedFolders, isEmpty);
    expect(of('cleanupDeletedFiles'), isEmpty);
    expect(of('batchFile').single['payload'], hasLength(1));
  });

  test('a failed batch write skips the deleted-file sweep', () async {
    failService = 'batchFile';
    final api = FakeCloudFileApi({
      'root': [_file('f1')],
    });
    await run(worker(), api, args());
    expect(of('cleanupDeletedFiles'), isEmpty);
  });

  test('download queue skips types the provider cannot download', () async {
    final api = FakeCloudFileApi({});
    File row(String id, String mime) => File(
      id: 'c1:$id',
      name: '$id.txt',
      path: 'fake://$id',
      parent: '',
      dateCreated: DateTime(2024),
      dateLastModified: DateTime(2024),
      collectionId: 'c1',
      contentType: mime,
      isDeleted: false,
      size: 1,
    );
    await run(
      worker(
        toDownload: [
          row('ok1', 'text/plain'),
          row('native', 'application/x-native-doc'),
          row('ok2', 'image/png'),
        ],
      ),
      api,
      args(download: true),
    );

    expect(api.downloaded, unorderedEquals(['ok1', 'ok2']));
    final recorded = of(
      'fileLocalPath',
    ).map((w) => (w['payload'] as Map)['fileId']);
    expect(recorded, unorderedEquals(['c1:ok1', 'c1:ok2']));
    expect(
      io.File(p.join(tmp, 'files', 'fake', 'My Drive', 'ok1.txt')).existsSync(),
      isTrue,
    );
  });

  test(
    'aborts without tokens and flags re-auth on a dead refresh token',
    () async {
      final api = FakeCloudFileApi({
        'root': [_file('f1')],
      });
      await run(worker(), api, {...args(), 'accessToken': null});
      expect(writes, isEmpty);

      await worker().scan(
        args(),
        (_) async => throw const CloudAuthException('dead', needsReAuth: true),
      );
      expect(writes.map((w) => w['service']), ['needsReAuth']);
    },
  );

  test(
    'a failed download leaves no file and is not recorded; retry works',
    () async {
      final api = FakeCloudFileApi({})..failDownloadsLeft = 1;
      final row = File(
        id: 'c1:x',
        name: 'x.txt',
        path: 'fake://x',
        parent: '',
        dateCreated: DateTime(2024),
        dateLastModified: DateTime(2024),
        collectionId: 'c1',
        contentType: 'text/plain',
        isDeleted: false,
        size: 1,
      );
      final dest = p.join(tmp, 'files', 'fake', 'My Drive', 'x.txt');

      await run(worker(toDownload: [row]), api, args(download: true));
      expect(io.File(dest).existsSync(), isFalse);
      expect(io.File('$dest.part').existsSync(), isFalse);
      expect(of('fileLocalPath'), isEmpty);

      await run(worker(toDownload: [row]), api, args(download: true));
      expect(io.File(dest).readAsStringSync(), 'bytes of x');
      expect(of('fileLocalPath'), hasLength(1));
    },
  );
}
