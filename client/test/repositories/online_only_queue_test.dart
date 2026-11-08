import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// Search has to cover every file in a sync folder (iCloud, Dropbox,
/// OneDrive...), including the online-only ones macOS has not downloaded.
/// The embedding, chunking and description queues must therefore hand those
/// files out like any other; the loader downloads each one and makes it
/// online-only again (see FileBytesLoader). A queue that filtered them out
/// would leave most of a large cloud library unsearchable.
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

  test('online-only images are queued for embedding', () async {
    await scan([
      file('local.jpg', 'image/jpeg', onlineOnly: false),
      file('cloud.jpg', 'image/jpeg', onlineOnly: true),
    ]);
    final queued = await DatabaseRepository(db).getFilesWithMissingEmbeddings();
    expect(
      queued.map((f) => f.name),
      unorderedEquals(['local.jpg', 'cloud.jpg']),
    );
  });

  test('online-only images are queued for descriptions', () async {
    await scan([
      file('local.jpg', 'image/jpeg', onlineOnly: false),
      file('cloud.jpg', 'image/jpeg', onlineOnly: true),
    ]);
    final queued =
        await DatabaseRepository(db).getFilesWithMissingDescriptions();
    expect(
      queued.map((f) => f.name),
      unorderedEquals(['local.jpg', 'cloud.jpg']),
    );
  });

  test('online-only documents are queued for chunking', () async {
    await scan([
      file('local.pdf', 'application/pdf', onlineOnly: false),
      file('cloud.pdf', 'application/pdf', onlineOnly: true),
    ]);
    final queued = await DatabaseRepository(db).getFilesWithMissingChunks();
    expect(
      queued.map((f) => f.name),
      unorderedEquals(['local.pdf', 'cloud.pdf']),
    );
  });
}
