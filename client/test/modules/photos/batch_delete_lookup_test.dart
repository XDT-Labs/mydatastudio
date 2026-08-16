import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/file_sources/file_source_file.dart';
import 'package:mydatastudio/file_sources/file_source_provider.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/files/services/utilities/system_trash.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// Counts the collection lookups a delete makes.
class _CountingRepository extends PhotosRepository {
  final List<String> collectionLookups = [];

  @override
  Future<Collection?> collectionFor(String collectionId) {
    collectionLookups.add(collectionId);
    return super.collectionFor(collectionId);
  }
}

/// Stands in for Google Drive, recording how the delete path calls it.
class _RecordingDrive extends FileSourceProvider {
  final List<List<String>> batches = [];
  int singleCalls = 0;

  @override
  String get providerKey => 'gdrive';
  @override
  String get scannerType => AppConstants.scannerFileGDrive;
  @override
  String get displayName => 'Google Drive';

  @override
  Future<List<FileSourceFile>> listFolder(Collection c, {String? folderId}) async => [];
  @override
  Future<io.File> downloadFile(Collection c, FileSourceFile f, String d) =>
      throw UnimplementedError();
  @override
  Future<void> openFile(Collection c, FileSourceFile f) async {}

  @override
  Future<bool> deleteFile(Collection c, FileSourceFile f) async {
    singleCalls++;
    return true;
  }

  @override
  Future<int> deleteFiles(Collection c, List<FileSourceFile> files) async {
    batches.add(files.map((f) => f.id).toList());
    return files.length;
  }
}

/// Records what was asked to go to the Trash instead of touching the real one.
class _RecordingTrash implements SystemTrash {
  final List<String> moved = [];

  @override
  Future<bool> moveToTrash(String path) async {
    moved.add(path);
    return true;
  }
}

/// Deleting a selection has to reach each photo's source, and the source is a
/// property of its collection — but a selection is drawn from a handful of
/// collections at most, however many photos it holds. Looking the collection up
/// per photo puts one query per photo on the single main-isolate connection,
/// where they queue behind each other, and a cleanup pass over a few hundred
/// photos is exactly the case this feature exists for.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('deleteSelectedFiles collection lookups', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late String localId;
    late String otherId;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mds_batchdel_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;

      localId = const Uuid().v4();
      otherId = const Uuid().v4();
      for (final id in [localId, otherId]) {
        await CollectionRepository(db).addCollection(
          Collection(
            id: id,
            name: 'Photos',
            path: tempDir.path,
            type: 'file',
            scanner: 'local',
            needsReAuth: false,
            scanStatus: 'idle',
          ),
        );
      }
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    File photo(String id, String collectionId) => File(
          id: id,
          name: '$id.jpg',
          path: '${tempDir.path}/$id.jpg',
          parent: tempDir.path,
          dateCreated: DateTime(2026, 1, 1),
          dateLastModified: DateTime(2026, 1, 1),
          collectionId: collectionId,
          contentType: 'image/jpeg',
          size: 1024,
          isDeleted: false,
        );

    test('one query per source, not one per photo', () async {
      final files = FileDesktopRepository(db);
      final ids = <String>{};
      for (var i = 0; i < 25; i++) {
        await files.create(photo('p$i', localId));
        ids.add('p$i');
      }

      final repo = _CountingRepository();
      final trash = _RecordingTrash();
      await BatchActionService.instance
          .deleteSelectedFiles(ids, trash: trash, repo: repo);

      expect(repo.collectionLookups, [localId],
          reason: '25 photos from one source is one collection, so one query');
      expect(trash.moved.length, 25,
          reason: 'and every photo still reaches the Trash');
    });

    test('a second source is looked up once too', () async {
      final files = FileDesktopRepository(db);
      await files.create(photo('a', localId));
      await files.create(photo('b', otherId));
      await files.create(photo('c', localId));

      final repo = _CountingRepository();
      await BatchActionService.instance.deleteSelectedFiles(
        {'a', 'b', 'c'},
        trash: _RecordingTrash(),
        repo: repo,
      );

      expect(repo.collectionLookups.toSet(), {localId, otherId});
      expect(repo.collectionLookups.length, 2,
          reason: 'revisiting a source must come from the cache');
    });

    // buildApi is per-call inside deleteFile: it re-reads the token and builds
    // a fresh authenticated client, and inside the five-minute refresh window
    // it refreshes against Google's token endpoint. Once per photo, a cleanup
    // pass becomes a refresh storm, which is how an OAuth client gets
    // throttled. One batched call per collection spends one.
    test('Drive files go in one batched call per collection', () async {
      final driveId = const Uuid().v4();
      await CollectionRepository(db).addCollection(
        Collection(
          id: driveId,
          name: 'Drive',
          path: '/drive',
          type: 'file',
          scanner: AppConstants.scannerFileGDrive,
          needsReAuth: false,
          scanStatus: 'idle',
        ),
      );

      final files = FileDesktopRepository(db);
      final ids = <String>{};
      for (var i = 0; i < 12; i++) {
        await files.create(File(
          id: 'd$i',
          name: 'd$i.jpg',
          path: 'gdrive://remote-$i',
          parent: '',
          dateCreated: DateTime(2026, 1, 1),
          dateLastModified: DateTime(2026, 1, 1),
          collectionId: driveId,
          contentType: 'image/jpeg',
          size: 1024,
          isDeleted: false,
        ));
        ids.add('d$i');
      }

      final drive = _RecordingDrive();
      final trash = _RecordingTrash();
      await BatchActionService.instance.deleteSelectedFiles(
        ids,
        trash: trash,
        providerFor: (_) => drive,
        repo: _CountingRepository(),
      );

      expect(drive.batches.length, 1,
          reason: '12 Drive photos from one collection is one call');
      expect(drive.batches.single.length, 12);
      expect(drive.singleCalls, 0,
          reason: 'the per-file path would rebuild the client each time');
      // Drive's own ids, not ours — they live in the path as `gdrive://<id>`.
      expect(drive.batches.single, contains('remote-0'));
      expect(trash.moved, isEmpty,
          reason: 'a Drive file has no local original to bin');
    });

    // Worth pinning because it is not obvious from the delete path itself:
    // filesByIds reaches the source columns through an INNER JOIN, so a photo
    // whose collection has gone never surfaces there at all. Nothing is looked
    // up and nothing is binned. That matches the gallery, which hides those
    // photos through the same join — but a later change to an outer join would
    // put files with no collection through a delete that has no source to
    // reach, and this is where that shows up.
    test('a photo whose collection has gone does not reach the delete path',
        () async {
      final files = FileDesktopRepository(db);
      for (final id in ['x', 'y', 'z']) {
        await files.create(photo(id, localId));
      }
      await db.execute('DELETE FROM collections WHERE id = ?', [localId]);

      final repo = _CountingRepository();
      final trash = _RecordingTrash();
      await BatchActionService.instance.deleteSelectedFiles(
        {'x', 'y', 'z'},
        trash: trash,
        repo: repo,
      );

      expect(repo.collectionLookups, isEmpty);
      expect(trash.moved, isEmpty);

      // The rows are still marked, which is what keeps them out of the gallery
      // and what survives the next Sync.
      final rows = await db.select(
        'SELECT id FROM files WHERE is_user_deleted = 1 ORDER BY id');
      expect(rows.map((r) => r['id']), ['x', 'y', 'z']);
    });
  });
}
