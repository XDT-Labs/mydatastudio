// Permanent vs transient read failures — search plan §18k.
//
// The distinction exists because the two call for opposite responses. A file
// on an unmounted NAS will read fine later, so the source backs off and the
// file keeps its retry budget. A Google Doc has no bytes to read and never
// will, so backing the source off stalls every other file behind a condition
// that has nothing to do with the source being reachable.
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/file_sources/sync_folder/file_evictor.dart';
import 'package:mydatastudio/file_sources/sync_folder/online_only_checker.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/file_bytes_loader.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';

class _MockRepo extends Mock implements DatabaseRepository {}

class _MockDb extends Mock implements AppDatabase {}

/// A cloud drive that serves fixed bytes, or throws [error] on download.
class _FakeDrive implements CloudFileApi {
  final Object? error;
  final List<String> downloaded = [];
  CloudFileApiCredentials? credentials;

  _FakeDrive({this.error});

  @override
  String get scheme => 'dropbox';

  @override
  Future<void> download(String id, String destPath) async {
    downloaded.add(id);
    if (error != null) throw error!;
    await io.File(destPath).writeAsBytes([1, 2, 3]);
  }

  @override
  bool isDownloadableMimeType(String mimeType) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Reports the paths in [paths] as online-only.
class _FakeOnlineOnly implements OnlineOnlyChecker {
  final Set<String> paths;
  _FakeOnlineOnly(this.paths);

  @override
  bool isOnlineOnly(String path) => paths.contains(path);
}

class _FakeEvictor implements FileEvictor {
  final bool succeeds;
  final List<String> evicted = [];
  _FakeEvictor({this.succeeds = true});

  @override
  Future<bool> evict(String path) async {
    evicted.add(path);
    return succeeds;
  }
}

void main() {
  group('isGoogleNativeFormat', () {
    test('recognises the Workspace editors', () {
      expect(
        FileBytesLoader.isGoogleNativeFormat(
          'application/vnd.google-apps.document',
        ),
        isTrue,
      );
      expect(
        FileBytesLoader.isGoogleNativeFormat(
          'application/vnd.google-apps.spreadsheet',
        ),
        isTrue,
      );
    });

    test('excludes folders, which are not documents at all', () {
      expect(
        FileBytesLoader.isGoogleNativeFormat(
          'application/vnd.google-apps.folder',
        ),
        isFalse,
      );
    });

    test('leaves ordinary Drive files alone', () {
      // A PDF or Word file *stored in* Drive downloads normally — only the
      // native editor formats have no byte representation.
      expect(FileBytesLoader.isGoogleNativeFormat('application/pdf'), isFalse);
      expect(FileBytesLoader.isGoogleNativeFormat('image/jpeg'), isFalse);
      expect(FileBytesLoader.isGoogleNativeFormat(null), isFalse);
    });
  });

  group('Workspace export targets', () {
    test('Docs and Sheets export to formats docling reads natively', () {
      // DOCX/XLSX rather than PDF: docling reads both with no model download,
      // so an exported Workspace file chunks through the same path as any
      // other document, heading paths included (§18k).
      expect(
        FileBytesLoader.exportTargetFor(
          'application/vnd.google-apps.document',
        )?.extension,
        'docx',
      );
      expect(
        FileBytesLoader.exportTargetFor(
          'application/vnd.google-apps.spreadsheet',
        )?.extension,
        'xlsx',
      );
    });

    test('has no target for Workspace types that are not documents', () {
      // Forms, Drawings and Sites have no useful document export; asking for
      // one is a round-trip that can only fail.
      for (final kind in ['form', 'drawing', 'site', 'shortcut']) {
        expect(
          FileBytesLoader.exportTargetFor('application/vnd.google-apps.$kind'),
          isNull,
          reason: kind,
        );
      }
    });

    test('has no target for ordinary files, which download directly', () {
      expect(FileBytesLoader.exportTargetFor('application/pdf'), isNull);
      expect(FileBytesLoader.exportTargetFor(null), isNull);
    });

    test('every queued Workspace type has somewhere to be exported to', () {
      // The queue lists these as a SQL literal and the loader as a map; if
      // they drift, a file is offered forever and never readable.
      for (final type in DatabaseRepository.exportableWorkspaceTypes) {
        expect(FileBytesLoader.exportTargetFor(type), isNotNull, reason: type);
      }
    });
  });

  group('FileBytes outcomes', () {
    test('a permanent failure is distinguishable from a transient one', () {
      const permanent = FileBytes.permanent();
      const transient = FileBytes.transient();

      expect(permanent.ok, isFalse);
      expect(transient.ok, isFalse);
      expect(permanent.permanent, isTrue);
      expect(
        transient.permanent,
        isFalse,
        reason: 'an outage must not spend a retry budget',
      );
    });

    test('success is never permanent', () {
      const result = FileBytes.ok([1, 2, 3]);
      expect(result.ok, isTrue);
      expect(result.permanent, isFalse);
      expect(result.bytes, [1, 2, 3]);
      expect(
        result.filenameHint,
        isNull,
        reason: 'only an export renames what it fetched',
      );
    });

    test('an export carries the name its bytes should be read as', () {
      const result = FileBytes.ok([1], filenameHint: 'Plan.md.docx');
      expect(
        result.filenameHint,
        'Plan.md.docx',
        reason:
            'DOCX and XLSX share a ZIP signature, so the extension is '
            'the only thing that tells the extractor which one it has',
      );
    });
  });

  group('cloud sources', () {
    late _MockRepo repo;
    final logger = AppLogger(null);

    File cloudFile(String path, {String? localPath}) => File(
      id: 'c1:x',
      name: 'photo.jpg',
      path: path,
      parent: '',
      dateCreated: DateTime(2026),
      dateLastModified: DateTime(2026),
      collectionId: 'c1',
      contentType: 'image/jpeg',
      size: 3,
      isDeleted: false,
      localPath: localPath,
    );

    setUp(() {
      repo = _MockRepo();
      when(() => repo.db).thenReturn(_MockDb());
      when(() => repo.getCollection('c1')).thenAnswer(
        (_) async => Collection(
          id: 'c1',
          name: 'Dropbox',
          path: 'root',
          type: 'file',
          scanner: 'dropbox',
          needsReAuth: false,
          scanStatus: 'idle',
          accessToken: 'at',
          refreshToken: 'rt',
        ),
      );
    });

    Map<String, CloudFileApiFactory> drives(_FakeDrive d) => {
      'dropbox': (c) async {
        d.credentials = c;
        return d;
      },
      'onedrive': (c) async {
        d.credentials = c;
        return d;
      },
    };

    test('a downloaded local copy is read instead of the network', () async {
      // The user asked for a local copy; fetching the file again for every
      // embedding pass would spend their bandwidth for bytes already on disk.
      final dir = await io.Directory.systemTemp.createTemp('fbl');
      addTearDown(() => dir.delete(recursive: true));
      final copy = io.File('${dir.path}/photo.jpg')..writeAsBytesSync([7, 7]);
      final drive = _FakeDrive();
      for (final path in ['dropbox://id:a', 'onedrive://A', 'gdrive://g']) {
        final r = await FileBytesLoader.loadDetailed(
          cloudFile(path, localPath: copy.path),
          repo,
          logger,
          cloudApis: drives(drive),
        );
        expect(r.bytes, [7, 7], reason: path);
      }
      expect(drive.downloaded, isEmpty);
    });

    test('Dropbox and OneDrive files are fetched from the provider', () async {
      // Before this, `dropbox://` paths were read as local paths, never
      // found, and the files never reached semantic search.
      for (final (path, id) in [
        ('dropbox://id:a', 'id:a'),
        ('onedrive://A', 'A'),
      ]) {
        final drive = _FakeDrive();
        final r = await FileBytesLoader.loadDetailed(
          cloudFile(path),
          repo,
          logger,
          cloudApis: drives(drive),
        );
        expect(r.bytes, [1, 2, 3], reason: path);
        expect(drive.downloaded, [id]);
        expect(drive.credentials!.accessToken, 'at');
        expect(drive.credentials!.refreshToken, 'rt');
      }
    });

    test('a missing local copy falls back to the provider', () async {
      final drive = _FakeDrive();
      final r = await FileBytesLoader.loadDetailed(
        cloudFile('dropbox://id:a', localPath: '/nowhere/photo.jpg'),
        repo,
        logger,
        cloudApis: drives(drive),
      );
      expect(r.bytes, [1, 2, 3]);
    });

    test('a file gone from the provider is permanent', () async {
      // Retrying cannot bring it back, and a transient result would back
      // off the whole collection for one deleted file.
      final r = await FileBytesLoader.loadDetailed(
        cloudFile('dropbox://id:a'),
        repo,
        logger,
        cloudApis: drives(
          _FakeDrive(error: const CloudFileNotFoundException('id:a')),
        ),
      );
      expect(r.ok, isFalse);
      expect(r.permanent, isTrue);
    });

    test('a network failure is transient', () async {
      final r = await FileBytesLoader.loadDetailed(
        cloudFile('onedrive://A'),
        repo,
        logger,
        cloudApis: drives(_FakeDrive(error: const io.SocketException('down'))),
      );
      expect(r.ok, isFalse);
      expect(r.permanent, isFalse);
    });

    test(
      'a token that cannot be refreshed is transient, not permanent',
      () async {
        // The file is fine; the account needs reconnecting. Spending the
        // file's attempts here would retire it for good.
        final r = await FileBytesLoader.loadDetailed(
          cloudFile('dropbox://id:a'),
          repo,
          logger,
          cloudApis: {
            'dropbox': (_) async => throw const CloudAuthException('expired'),
          },
        );
        expect(r.ok, isFalse);
        expect(r.permanent, isFalse);
      },
    );
  });

  // Search has to cover a whole sync folder, but reading an online-only file
  // makes macOS download it. Indexing a large iCloud or Dropbox library must
  // not leave all of it on the user's disk, so each online-only file is
  // evicted again once its bytes are read.
  group('sync-folder files', () {
    late io.Directory dir;
    final logger = AppLogger(null);
    final repo = _MockRepo();

    setUp(() => dir = io.Directory.systemTemp.createTempSync('mds_sync_'));
    tearDown(() => dir.deleteSync(recursive: true));

    File syncFile(String path) => File(
      id: 'icloud:x',
      name: 'photo.jpg',
      path: path,
      parent: '',
      dateCreated: DateTime(2026),
      dateLastModified: DateTime(2026),
      collectionId: 'icloud',
      contentType: 'image/jpeg',
      size: 3,
      isDeleted: false,
    );

    String write(String name) {
      final path = '${dir.path}/$name';
      io.File(path).writeAsBytesSync([7, 8, 9]);
      return path;
    }

    test('an online-only file is read, then made online-only again', () async {
      final path = write('photo.jpg');
      final evictor = _FakeEvictor();
      // The row says "on disk" (scanned before the provider evicted it): the
      // read-time check is what decides.
      final r = await FileBytesLoader.loadDetailed(
        syncFile(path),
        repo,
        logger,
        onlineOnly: _FakeOnlineOnly({path}),
        evictor: evictor,
      );
      expect(r.bytes, [7, 8, 9]);
      expect(evictor.evicted, [path]);
    });

    test('a file the user downloaded is never evicted', () async {
      final path = write('photo.jpg');
      final evictor = _FakeEvictor();
      final r = await FileBytesLoader.loadDetailed(
        syncFile(path),
        repo,
        logger,
        onlineOnly: _FakeOnlineOnly({}),
        evictor: evictor,
      );
      expect(r.bytes, [7, 8, 9]);
      expect(evictor.evicted, isEmpty);
    });

    test('a failed eviction still indexes the file', () async {
      final path = write('photo.jpg');
      final r = await FileBytesLoader.loadDetailed(
        syncFile(path),
        repo,
        logger,
        onlineOnly: _FakeOnlineOnly({path}),
        evictor: _FakeEvictor(succeeds: false),
      );
      expect(r.bytes, [7, 8, 9]);
    });

    test(
      'a download that fails is transient, and nothing is evicted',
      () async {
        // A directory stands in for a file the provider cannot download
        // (offline, signed out): reading it throws FileSystemException.
        final path = '${dir.path}/offline.jpg';
        io.Directory(path).createSync();
        final evictor = _FakeEvictor();
        final r = await FileBytesLoader.loadDetailed(
          syncFile(path),
          repo,
          logger,
          onlineOnly: _FakeOnlineOnly({path}),
          evictor: evictor,
        );
        expect(r.ok, isFalse);
        expect(r.permanent, isFalse);
        expect(evictor.evicted, isEmpty);
      },
    );

    test('a legacy iCloud placeholder is permanent', () async {
      // macOS 15+ cannot download a `.photo.jpg.icloud` stub, so retrying it
      // would only hold up the rest of the folder.
      write('.photo.jpg.icloud');
      final r = await FileBytesLoader.loadDetailed(
        syncFile('${dir.path}/photo.jpg'),
        repo,
        logger,
        onlineOnly: _FakeOnlineOnly({}),
        evictor: _FakeEvictor(),
      );
      expect(r.permanent, isTrue);
    });
  });
}
