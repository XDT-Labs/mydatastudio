import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// An online-only file in a sync folder (iCloud, Dropbox, OneDrive...) is
/// downloaded by macOS the moment anything reads it. The embedding, chunking
/// and description queues all read the files they are handed, so an
/// online-only file must not be handed to them: indexing would otherwise pull
/// down the whole cloud library. Once the file is on disk, a rescan clears the
/// flag and it is queued like any other.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory tempDir;
  late DatabaseManager dm;
  late AppDatabase db;

  setUp(() async {
    tempDir = await io.Directory.systemTemp.createTemp('mds_online_only_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);
    dm = DatabaseManager.instance;
    await dm.initializeDatabase();
    db = dm.database!;
    await CollectionRepository(db).addCollection(
      Collection(
        id: 'icloud',
        name: 'iCloud Drive',
        path: '/icloud',
        type: 'file',
        scanner: 'local',
        needsReAuth: false,
        scanStatus: 'idle',
      ),
    );
  });

  tearDown(() async {
    dm.dispose();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  File file(String name, String type, {required bool onlineOnly}) => File(
    id: 'icloud:$name',
    name: name,
    path: name,
    parent: '',
    dateCreated: DateTime(2026),
    dateLastModified: DateTime(2026),
    collectionId: 'icloud',
    contentType: type,
    size: 1,
    isDeleted: false,
    isOnlineOnly: onlineOnly,
  );

  /// Writes through the scanners' upsert, the path that sets the flag.
  Future<void> scan(List<File> files) =>
      FileDesktopRepository(db).upsertAll(files);

  test('online-only images are left out of the embedding queue', () async {
    await scan([
      file('local.jpg', 'image/jpeg', onlineOnly: false),
      file('cloud.jpg', 'image/jpeg', onlineOnly: true),
    ]);
    final queued = await DatabaseRepository(db).getFilesWithMissingEmbeddings();
    expect(queued.map((f) => f.name), ['local.jpg']);
  });

  test('online-only images are left out of the description queue', () async {
    await scan([
      file('local.jpg', 'image/jpeg', onlineOnly: false),
      file('cloud.jpg', 'image/jpeg', onlineOnly: true),
    ]);
    final queued =
        await DatabaseRepository(db).getFilesWithMissingDescriptions();
    expect(queued.map((f) => f.name), ['local.jpg']);
  });

  test('online-only documents are left out of the chunk queue', () async {
    await scan([
      file('local.pdf', 'application/pdf', onlineOnly: false),
      file('cloud.pdf', 'application/pdf', onlineOnly: true),
    ]);
    final queued = await DatabaseRepository(db).getFilesWithMissingChunks();
    expect(queued.map((f) => f.name), ['local.pdf']);
  });

  test('a file downloaded since the last scan is queued again', () async {
    await scan([file('photo.jpg', 'image/jpeg', onlineOnly: true)]);
    expect(
      await DatabaseRepository(db).getFilesWithMissingEmbeddings(),
      isEmpty,
    );

    await scan([file('photo.jpg', 'image/jpeg', onlineOnly: false)]);
    final queued = await DatabaseRepository(db).getFilesWithMissingEmbeddings();
    expect(queued.map((f) => f.name), ['photo.jpg']);
  });
}
