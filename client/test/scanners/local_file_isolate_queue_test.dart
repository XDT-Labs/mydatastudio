import 'dart:async';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:resqlite/resqlite.dart';
import 'package:mydatastudio/modules/files/services/scanners/local_file_isolate.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:image/image.dart' as img;
import 'dart:io' as io;
import 'package:path/path.dart' as p;

class MockAppDatabase extends Mock implements AppDatabase {}
class MockSendPort extends Mock implements SendPort {}

void main() {
  late MockAppDatabase mockDb;
  late MockSendPort mockPort;
  late LocalFileIsolateWorker worker;
  late String tempDir;

  setUp(() {
    mockDb = MockAppDatabase();
    mockPort = MockSendPort();
    tempDir = io.Directory.systemTemp.createTempSync('thumb_queue_test').path;
    // Use tempDir as the storage root so cached thumbnails land under
    // tempDir/thumbnails and get cleaned up in tearDown.
    worker = LocalFileIsolateWorker(
      null,
      mockPort,
      tempDir,
      'test.db',
      mockPort,
    );
  });

  tearDown(() {
    io.Directory(tempDir).deleteSync(recursive: true);
  });

  test('LocalFileIsolateWorker background queue processes jobs and updates database', () async {
    // Generate a simple dummy image
    final image = img.Image(width: 100, height: 100);
    img.fill(image, color: img.ColorRgb8(255, 0, 0));
    final path = p.join(tempDir, 'landscape.jpg');
    io.File(path).writeAsBytesSync(img.encodeJpg(image));

    // Stub the database execute method
    when(() => mockDb.execute(any(), any())).thenAnswer((_) async => const WriteResult(0, 0));

    // Enqueue the thumbnail job
    worker.enqueueThumbnailJobForTesting(
      mockDb,
      'test-collection-id',
      'test-file-id',
      path,
      FilesConstants.mimeTypeImage,
      null,
    );

    // Give it a moment to process the async queue
    await Future.delayed(const Duration(milliseconds: 200));

    // Verify that it called database.execute to update the thumbnail
    verify(() => mockDb.execute(
      "UPDATE files SET thumbnail = ? WHERE id = ?",
      any(),
    )).called(1);

    expect(worker.activeThumbnailJobsForTesting, 0);
    expect(worker.queueLengthForTesting, 0);
  });

  // The scanner is handed two roots: `storagePath` is the *database* directory
  // and `appDir` is the user's storage root. They diverge whenever the chosen
  // storage location can't run SQLite in WAL mode, because the db is then
  // redirected to Application Support. ThumbnailResolver reads thumbnails back
  // through MainApp.appDataDirectory — the storage root — so writing them under
  // the database directory means every thumbnail in the UI renders as a broken
  // image even though the jpegs exist on disk.
  test('thumbnails are cached under appDir, not the database directory', () async {
    final dbDir = io.Directory.systemTemp.createTempSync('thumb_db_dir').path;
    final storageRoot = io.Directory.systemTemp
        .createTempSync('thumb_storage_root')
        .path;
    addTearDown(() {
      io.Directory(dbDir).deleteSync(recursive: true);
      io.Directory(storageRoot).deleteSync(recursive: true);
    });

    final splitWorker = LocalFileIsolateWorker(
      null,
      mockPort,
      dbDir,
      'test.db',
      mockPort,
      appDir: storageRoot,
    );

    final image = img.Image(width: 100, height: 100);
    img.fill(image, color: img.ColorRgb8(0, 255, 0));
    final path = p.join(tempDir, 'split-roots.jpg');
    io.File(path).writeAsBytesSync(img.encodeJpg(image));

    String? savedKey;
    when(() => mockDb.execute(any(), any())).thenAnswer((invocation) async {
      savedKey =
          (invocation.positionalArguments[1] as List).first as String;
      return const WriteResult(0, 0);
    });

    splitWorker.enqueueThumbnailJobForTesting(
      mockDb,
      'test-collection-id',
      'test-file-id',
      path,
      FilesConstants.mimeTypeImage,
      null,
    );

    await Future.delayed(const Duration(milliseconds: 200));

    expect(savedKey, isNotNull);
    // The key stored in files.thumbnail must resolve under the storage root,
    // which is exactly what the UI does.
    expect(
      io.File(p.join(storageRoot, 'thumbnails', savedKey!)).existsSync(),
      isTrue,
    );
    expect(io.Directory(p.join(dbDir, 'thumbnails')).existsSync(), isFalse);
  });
}
