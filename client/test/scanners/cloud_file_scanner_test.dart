import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_scanner.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';
import 'package:path/path.dart' as p;

class _MockDb extends Mock implements AppDatabase {}

/// In-memory drive: folderId -> children. Pages hold [pageSize] entries.
class FakeCloudFileApi implements CloudFileApi {
  final Map<String, List<CloudFileEntry>> tree;
  final int pageSize;
  final List<String> listedFolders = [];
  final List<String> downloaded = [];

  /// Change pages served in order; cursor pN addresses page N, any other
  /// cursor starts at page 0.
  final List<List<CloudChange>> changePages;

  /// Call order across the API: startCursor, list:FOLDER, changes.
  final List<String> events = [];
  bool cursorExpired = false;
  int failDownloadsLeft = 0;

  FakeCloudFileApi(
    this.tree, {
    this.pageSize = 1000,
    this.changePages = const [],
  });

  @override
  String get scheme => 'fake';

  @override
  Future<CloudFilePage> listChildren(
    String folderId, {
    String? pageToken,
  }) async {
    if (pageToken == null) {
      listedFolders.add(folderId);
      events.add('list:$folderId');
    }
    final all = tree[folderId] ?? const [];
    final start = int.parse(pageToken ?? '0');
    final end = (start + pageSize).clamp(0, all.length);
    return CloudFilePage(
      all.sublist(start, end),
      nextPageToken: end < all.length ? '$end' : null,
    );
  }

  @override
  Future<String> startCursor() async {
    events.add('startCursor');
    return 'c-start';
  }

  @override
  Future<CloudChangePage> listChanges(String cursor) async {
    events.add('changes');
    if (cursorExpired) throw const CloudCursorExpiredException();
    final i = cursor.startsWith('p') ? int.parse(cursor.substring(1)) : 0;
    final last = i + 1 >= changePages.length;
    return CloudChangePage(
      changePages.isEmpty ? const [] : changePages[i],
      nextPageCursor: last ? null : 'p${i + 1}',
      newStartCursor: last ? 'c-new' : null,
    );
  }

  /// The real id behind the 'root' alias, as Drive reports it in `parents`.
  @override
  Future<CloudFileEntry?> getEntry(String id) async =>
      id == 'root' ? _folder('REALROOT') : null;

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

/// A provider that renders thumbnails server-side (Dropbox, OneDrive).
class FakeThumbnailApi extends FakeCloudFileApi implements ServerThumbnails {
  final List<List<String>> thumbnailCalls = [];

  /// Ids the provider can't render; they are absent from the result.
  final Set<String> missing;

  FakeThumbnailApi(super.tree, {super.changePages, this.missing = const {}});

  @override
  int get thumbnailBatchSize => 2;

  @override
  bool offersThumbnail(String name, String? mimeType) => name.endsWith('.jpg');

  @override
  Future<Map<String, Uint8List>> thumbnails(List<String> ids) async {
    thumbnailCalls.add(ids);
    return {
      for (final id in ids)
        if (!missing.contains(id)) id: Uint8List.fromList(id.codeUnits),
    };
  }
}

File _row(String id, String name) => File(
  id: 'c1:$id',
  collectionId: 'c1',
  name: name,
  path: 'fake://$id',
  parent: '',
  dateCreated: DateTime(2024),
  dateLastModified: DateTime(2024),
  lastScannedDate: DateTime(2024),
  isDeleted: false,
  size: 5,
  contentType: 'image/jpeg',
);

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
    String? cursor,
    bool keepDeleted = false,
    String? policy,
  }) => {
    'collectionId': 'c1',
    'collectionName': 'My Drive',
    'collectionPath': 'root',
    'rootFolderId': root,
    'isFullScan': fullScan,
    'force': force,
    'recursive': recursive,
    'downloadLocalCopy': download,
    'contentPolicy': policy,
    'lastScanDate': lastScan,
    'changeCursor': cursor,
    'keepDeletedFiles': keepDeleted,
    'appDir': tmp,
    'accessToken': 'a',
    'refreshToken': 'r',
  };

  CloudFileScannerWorker worker({
    List<File> toDownload = const [],
    List<File> withoutThumbnail = const [],
    Map<String, String> knownFolders = const {},
  }) => CloudFileScannerWorker(
    _MockDb(),
    null,
    port.sendPort,
    collectionExists: (_) async => true,
    filesToDownload: (_) async => toDownload,
    filesWithoutThumbnail: (_) async => withoutThumbnail,
    knownFolders: (_) async => knownFolders,
  );

  Future<void> run(
    CloudFileScannerWorker w,
    CloudFileApi api,
    Map<String, dynamic> a,
  ) => w.scan(a, (_) async => api);

  Iterable<Map> of(String service) =>
      writes.where((w) => w['service'] == service);

  /// Cursor values relayed to main, in order (null = cleared).
  List<String?> cursorWrites() =>
      of(
        'collectionChangeCursor',
      ).map((w) => (w['payload'] as Map)['cursor'] as String?).toList();

  Map removal() => of('cloudRemovals').single['payload'] as Map;

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
        'collectionChangeCursor',
        'collectionStatus',
      ]);
      final cleanup = of('cleanupDeletedFiles').single['payload'] as Map;
      expect(cleanup['isCloud'], true);
      expect(cleanup['path'], '');
    },
  );

  group('change-cursor sync', () {
    test(
      'full walk takes the start cursor before walking, persists it after',
      () async {
        final api = FakeCloudFileApi({
          'root': [_file('f1')],
        });
        await run(worker(), api, args());
        expect(api.events.first, 'startCursor');
        expect(
          api.events.indexOf('startCursor'),
          lessThan(api.events.indexOf('list:root')),
        );
        expect(cursorWrites(), ['c-start']);
        // Persisted only after the files were written.
        final services = writes.map((w) => w['service']).toList();
        expect(
          services.indexOf('collectionChangeCursor'),
          greaterThan(services.indexOf('batchFile')),
        );
      },
    );

    test('a failed batch leaves the cursor unwritten', () async {
      failService = 'batchFile';
      final api = FakeCloudFileApi({
        'root': [_file('f1')],
      });
      await run(worker(), api, args());
      expect(cursorWrites(), isEmpty);
    });

    // start() only ever spawns forced syncs, so a forced sync with a stored
    // cursor must use the change feed; otherwise incremental sync never runs
    // in the app and every sync re-lists the whole Drive.
    test('a forced sync with a stored cursor is incremental', () async {
      final api = FakeCloudFileApi({
        'root': [_file('f1')],
      });
      await run(worker(), api, args(cursor: 'old'));
      expect(api.events, contains('changes'));
      expect(api.listedFolders, isEmpty);
      expect(of('cleanupDeletedFiles'), isEmpty);
    });

    test(
      'incremental upserts changes, never sweeps, stores the new cursor',
      () async {
        final api = FakeCloudFileApi(
          {},
          changePages: [
            [
              CloudChange(
                'f9',
                entry: const CloudFileEntry(
                  id: 'f9',
                  name: 'f9.txt',
                  parentIds: ['REALROOT'],
                ),
              ),
            ],
          ],
        );
        await run(worker(), api, args(force: false, cursor: 'old'));
        expect(api.listedFolders, isEmpty);
        expect(of('cleanupDeletedFiles'), isEmpty);
        final f = (of('batchFile').single['payload'] as List<File>).single;
        expect(
          f.parent,
          '',
          reason: 'real root id maps to the collection root',
        );
        expect(cursorWrites(), ['c-new']);
      },
    );

    test('follows change pages', () async {
      final api = FakeCloudFileApi(
        {},
        changePages: [
          [
            CloudChange(
              'a',
              entry: const CloudFileEntry(
                id: 'a',
                name: 'a',
                parentIds: ['REALROOT'],
              ),
            ),
          ],
          [
            CloudChange(
              'b',
              entry: const CloudFileEntry(
                id: 'b',
                name: 'b',
                parentIds: ['REALROOT'],
              ),
            ),
          ],
        ],
      );
      await run(worker(), api, args(force: false, cursor: 'old'));
      final files = of('batchFile').expand((w) => w['payload'] as List<File>);
      expect(files.map((f) => f.path), ['fake://a', 'fake://b']);
      expect(cursorWrites(), ['c-new']);
    });

    test('removed item is relayed as a delete', () async {
      final api = FakeCloudFileApi(
        {},
        changePages: [
          [const CloudChange('gone', removed: true)],
        ],
      );
      await run(worker(), api, args(force: false, cursor: 'old'));
      expect(removal()['itemIds'], ['c1:gone']);
      expect(removal()['keepDeleted'], false);
      expect(of('batchFile'), isEmpty);
    });

    test(
      'with keep_deleted_files the removal is flagged keepDeleted',
      () async {
        final api = FakeCloudFileApi(
          {},
          changePages: [
            [const CloudChange('gone', removed: true)],
          ],
        );
        await run(
          worker(),
          api,
          args(force: false, cursor: 'old', keepDeleted: true),
        );
        expect(removal()['keepDeleted'], true);
      },
    );

    test('a move within the collection updates the parent', () async {
      final api = FakeCloudFileApi(
        {},
        changePages: [
          [
            CloudChange(
              'f',
              entry: const CloudFileEntry(
                id: 'f',
                name: 'f.txt',
                parentIds: ['a'],
              ),
            ),
          ],
        ],
      );
      await run(
        worker(knownFolders: {'a': ''}),
        api,
        args(force: false, cursor: 'old'),
      );
      final f = (of('batchFile').single['payload'] as List<File>).single;
      expect(f.parent, 'a');
    });

    test('a moved folder is rewritten with its new parent', () async {
      final api = FakeCloudFileApi(
        {},
        changePages: [
          [
            CloudChange(
              'b',
              entry: const CloudFileEntry(
                id: 'b',
                name: 'b',
                isFolder: true,
                parentIds: ['a'],
              ),
            ),
          ],
        ],
      );
      await run(
        worker(knownFolders: {'a': '', 'b': ''}),
        api,
        args(force: false, cursor: 'old'),
      );
      final fo = of('folder').single['payload'] as Folder;
      expect((fo.path, fo.parent), ('b', 'a'));
      expect(api.listedFolders, isEmpty, reason: 'already known: no re-walk');
    });

    test('changes outside the collection subtree are ignored', () async {
      final api = FakeCloudFileApi(
        {},
        changePages: [
          [
            CloudChange(
              'x',
              entry: const CloudFileEntry(
                id: 'x',
                name: 'x',
                parentIds: ['elsewhere'],
              ),
            ),
          ],
        ],
      );
      await run(
        worker(knownFolders: {'a': ''}),
        api,
        args(force: false, cursor: 'old', root: 'a'),
      );
      expect(of('batchFile'), isEmpty);
      expect(of('folder'), isEmpty);
    });

    test('an item moved out of scope is removed', () async {
      final api = FakeCloudFileApi(
        {},
        changePages: [
          [
            CloudChange(
              'f',
              entry: const CloudFileEntry(
                id: 'f',
                name: 'f',
                parentIds: ['elsewhere'],
              ),
            ),
            CloudChange(
              'a',
              entry: const CloudFileEntry(
                id: 'a',
                name: 'a',
                isFolder: true,
                parentIds: ['elsewhere'],
              ),
            ),
          ],
        ],
      );
      await run(
        worker(knownFolders: {'a': '', 'b': 'a'}),
        api,
        args(force: false, cursor: 'old'),
      );
      expect(of('batchFile'), isEmpty);
      final r = removal();
      expect(r['itemIds'], containsAll(['c1:f', 'c1:a', 'c1:b']));
      expect(
        r['parentIds'],
        containsAll(['a', 'b']),
        reason: 'descendants go too',
      );
    });

    test(
      'removing the top of a 3-level tree removes every descendant folder',
      () async {
        final api = FakeCloudFileApi(
          {},
          changePages: [
            [const CloudChange('a', removed: true)],
          ],
        );
        await run(
          worker(knownFolders: {'a': '', 'b': 'a', 'c': 'b', 'other': ''}),
          api,
          args(force: false, cursor: 'old'),
        );
        final r = removal();
        expect(r['parentIds'], unorderedEquals(['a', 'b', 'c']));
        expect(r['itemIds'], unorderedEquals(['c1:a', 'c1:b', 'c1:c']));
      },
    );

    test('a folder moved into scope is walked', () async {
      final api = FakeCloudFileApi(
        {
          'n': [_file('x')],
        },
        changePages: [
          [
            CloudChange(
              'n',
              entry: const CloudFileEntry(
                id: 'n',
                name: 'n',
                isFolder: true,
                parentIds: ['a'],
              ),
            ),
          ],
        ],
      );
      await run(
        worker(knownFolders: {'a': ''}),
        api,
        args(force: false, cursor: 'old'),
      );
      expect(api.listedFolders, ['n']);
      final files = of('batchFile').expand((w) => w['payload'] as List<File>);
      expect(files.map((f) => f.path), ['fake://x']);
    });

    test(
      'a file created inside a folder created in the same batch is in scope',
      () async {
        final api = FakeCloudFileApi(
          {'n': []},
          changePages: [
            [
              CloudChange(
                'f',
                entry: const CloudFileEntry(
                  id: 'f',
                  name: 'f',
                  parentIds: ['n'],
                ),
              ),
              CloudChange(
                'n',
                entry: const CloudFileEntry(
                  id: 'n',
                  name: 'n',
                  isFolder: true,
                  parentIds: ['REALROOT'],
                ),
              ),
            ],
          ],
        );
        await run(worker(), api, args(force: false, cursor: 'old'));
        final files = of('batchFile').expand((w) => w['payload'] as List<File>);
        expect(files.single.parent, 'n');
      },
    );

    test(
      'a failed write keeps the old cursor so the next run replays',
      () async {
        failService = 'batchFile';
        final api = FakeCloudFileApi(
          {},
          changePages: [
            [
              CloudChange(
                'f',
                entry: const CloudFileEntry(
                  id: 'f',
                  name: 'f',
                  parentIds: ['REALROOT'],
                ),
              ),
            ],
          ],
        );
        await run(worker(), api, args(force: false, cursor: 'old'));
        expect(cursorWrites(), isEmpty);
      },
    );

    test('a failed removal write keeps the old cursor', () async {
      failService = 'cloudRemovals';
      final api = FakeCloudFileApi(
        {},
        changePages: [
          [const CloudChange('gone', removed: true)],
        ],
      );
      await run(worker(), api, args(force: false, cursor: 'old'));
      expect(cursorWrites(), isEmpty);
    });

    test(
      'an expired cursor clears it, re-lists, sweeps, and stores a fresh one',
      () async {
        final api = FakeCloudFileApi({
          'root': [_file('f1')],
        })..cursorExpired = true;
        await run(worker(), api, args(force: false, cursor: 'old'));
        expect(api.listedFolders, ['root']);
        expect(of('cleanupDeletedFiles'), hasLength(1));
        expect(cursorWrites(), [null, 'c-start']);
      },
    );

    test('the sweep honours keep_deleted_files', () async {
      final api = FakeCloudFileApi({
        'root': [_file('f1')],
      });
      await run(worker(), api, args(keepDeleted: true));
      expect(of('cleanupDeletedFiles').single['payload']['keepDeleted'], true);
    });
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
    'download queue applies the content policy (category and size)',
    () async {
      final api = FakeCloudFileApi({});
      File row(String id, String mime, int size) => File(
        id: 'c1:$id',
        name: id,
        path: 'fake://$id',
        parent: '',
        dateCreated: DateTime(2024),
        dateLastModified: DateTime(2024),
        collectionId: 'c1',
        contentType: mime,
        isDeleted: false,
        size: size,
      );
      await run(
        worker(
          toDownload: [
            row('small.png', 'image/png', 10),
            row('big.png', 'image/png', 1000),
            row('clip.mp4', 'video/mp4', 10),
          ],
        ),
        api,
        args(
          // The legacy flag is off: the stored policy alone drives downloads.
          policy:
              const ContentPolicy(
                downloadCategories: {ContentCategory.images},
                maxFileBytes: 100,
              ).encode(),
        ),
      );
      expect(api.downloaded, ['small.png']);
    },
  );

  test('download_local_copy=false with no policy downloads nothing', () async {
    final api = FakeCloudFileApi({});
    await run(worker(), api, args());
    expect(api.downloaded, isEmpty);
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

  group('server-side thumbnails', () {
    Map<String, String> thumbnailWrites() => {
      for (final w in of('fileThumbnail'))
        (w['payload'] as Map)['fileId'] as String:
            (w['payload'] as Map)['thumbnailKey'] as String,
    };

    test(
      'images without a thumbnail are cached on disk and keyed on the row',
      () async {
        final api = FakeThumbnailApi({});
        await run(
          worker(
            withoutThumbnail: [
              _row('a', 'a.jpg'),
              _row('b', 'b.jpg'),
              _row('c', 'c.jpg'),
              _row('t', 'notes.txt'),
            ],
          ),
          api,
          args(),
        );

        // Batched at the provider's size; files it can't render aren't asked.
        expect(api.thumbnailCalls, [
          ['a', 'b'],
          ['c'],
        ]);
        final cache = ThumbnailCache(tmp);
        final writes = thumbnailWrites();
        expect(writes.keys, unorderedEquals(['c1:a', 'c1:b', 'c1:c']));
        // The row stores the cache key the UI resolves, and the bytes are there.
        expect(writes['c1:a'], cache.keyFor('c1', 'c1:a'));
        expect(cache.fileForKey(writes['c1:a']!).readAsStringSync(), 'a');
      },
    );

    test('an item the provider could not render gets no row write', () async {
      final api = FakeThumbnailApi({}, missing: {'b'});
      await run(
        worker(withoutThumbnail: [_row('a', 'a.jpg'), _row('b', 'b.jpg')]),
        api,
        args(),
      );
      expect(thumbnailWrites().keys, ['c1:a']);
    });

    test(
      'a changed image is fetched again even though it has a thumbnail',
      () async {
        // The stored thumbnail shows the old content. Only the change feed
        // knows the file changed: it isn't in the "no thumbnail" query.
        final api = FakeThumbnailApi(
          {},
          changePages: [
            [
              CloudChange(
                'p1',
                entry: const CloudFileEntry(
                  id: 'p1',
                  name: 'p1.jpg',
                  parentIds: ['REALROOT'],
                ),
              ),
            ],
          ],
        );
        await run(worker(), api, args(force: false, cursor: 'old'));
        expect(api.thumbnailCalls, [
          ['p1'],
        ]);
        expect(thumbnailWrites().keys, ['c1:p1']);
      },
    );

    test('a provider without server thumbnails is never asked', () async {
      final api = FakeCloudFileApi({
        'root': [_file('a')],
      });
      await run(worker(withoutThumbnail: [_row('a', 'a.jpg')]), api, args());
      expect(of('fileThumbnail'), isEmpty);
    });
  });
}
