import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// Regression coverage for the Photos map view bug where GPS coordinates
/// extracted by ExifExtractor were silently dropped: `upsertAll`'s
/// `ON CONFLICT(id) DO UPDATE SET` clause listed every updatable column
/// except `latitude`/`longitude`, so a rescan of an already-indexed file
/// (the common case — the local scanner hits its metadata cache and only
/// then discovers a missing GPS value) INSERTed the coordinates as bind
/// params that SQLite then ignored in favor of the UPDATE branch's column
/// list, leaving the row's latitude/longitude at NULL forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory tempDir;
  late DatabaseManager databaseManager;
  late AppDatabase db;
  late FileDesktopRepository repo;

  setUp(() async {
    tempDir = await io.Directory.systemTemp.createTemp(
      'mydatastudio_file_repo_',
    );

    const MethodChannel channel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return tempDir.path;
        });

    databaseManager = DatabaseManager.instance;
    await databaseManager.initializeDatabase();
    db = databaseManager.database!;
    repo = FileDesktopRepository(db);

    await CollectionRepository(db).addCollection(
      Collection(
        id: 'col-1',
        name: 'Test',
        path: tempDir.path,
        type: 'file',
        scanner: 'file.local',
        scanStatus: 'idle',
        needsReAuth: false,
        localCopyPath: tempDir.path,
      ),
    );
  });

  tearDown(() async {
    databaseManager.dispose();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  File makeFile({double? latitude, double? longitude}) {
    final now = DateTime.now();
    return File(
      id: 'col-1:photo.jpg',
      name: 'photo.jpg',
      path: 'photo.jpg',
      parent: '',
      dateCreated: now,
      dateLastModified: now,
      collectionId: 'col-1',
      contentType: FilesConstants.mimeTypeImage,
      size: 3,
      isDeleted: false,
      latitude: latitude,
      longitude: longitude,
    );
  }

  group('FileDesktopRepository.upsertAll — GPS coordinates', () {
    test('a fresh insert persists latitude/longitude', () async {
      await repo.upsertAll([makeFile(latitude: 37.7749, longitude: -122.4194)]);

      final saved = await repo.getByPath(makeFile());
      expect(saved?.latitude, closeTo(37.7749, 0.0001));
      expect(saved?.longitude, closeTo(-122.4194, 0.0001));
    });

    test(
      'a re-scan of an already-indexed file (the ON CONFLICT path) persists '
      'newly-discovered coordinates, not just newly-inserted ones',
      () async {
        // First scan: file discovered before GPS extraction ran (or the file
        // had none at the time).
        await repo.upsertAll([makeFile()]);
        var saved = await repo.getByPath(makeFile());
        expect(saved?.latitude, isNull);

        // Second scan: same file id (mtime cache miss or GPS backfill),
        // this time carrying coordinates — goes through ON CONFLICT DO UPDATE.
        await repo.upsertAll([
          makeFile(latitude: 37.7749, longitude: -122.4194),
        ]);

        saved = await repo.getByPath(makeFile());
        expect(saved?.latitude, closeTo(37.7749, 0.0001));
        expect(saved?.longitude, closeTo(-122.4194, 0.0001));
      },
    );
  });
}
