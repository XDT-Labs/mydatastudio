import 'dart:async';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
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

    // Stub the database execute method. affectedRows: 1 simulates the file
    // row already being present, so the job succeeds on its first attempt.
    final updateCompleter = Completer<void>();
    when(() => mockDb.execute(any(), any())).thenAnswer((_) async {
      if (!updateCompleter.isCompleted) updateCompleter.complete();
      return const WriteResult(1, 0);
    });

    // Enqueue the thumbnail job
    worker.enqueueThumbnailJobForTesting(
      mockDb,
      'test-collection-id',
      'test-file-id',
      path,
      FilesConstants.mimeTypeImage,
      null,
    );

    await updateCompleter.future.timeout(const Duration(seconds: 5));
    // Let the queue's post-job bookkeeping (activeJobs--, _processThumbnailQueue) run.
    await Future.delayed(Duration.zero);

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
    final savedKeyCompleter = Completer<void>();
    when(() => mockDb.execute(any(), any())).thenAnswer((invocation) async {
      savedKey =
          (invocation.positionalArguments[1] as List).first as String;
      if (!savedKeyCompleter.isCompleted) savedKeyCompleter.complete();
      return const WriteResult(1, 0);
    });

    splitWorker.enqueueThumbnailJobForTesting(
      mockDb,
      'test-collection-id',
      'test-file-id',
      path,
      FilesConstants.mimeTypeImage,
      null,
    );

    await savedKeyCompleter.future.timeout(const Duration(seconds: 5));

    expect(savedKey, isNotNull);
    // The key stored in files.thumbnail must resolve under the storage root,
    // which is exactly what the UI does.
    expect(
      io.File(p.join(storageRoot, 'thumbnails', savedKey!)).existsSync(),
      isTrue,
    );
    expect(io.Directory(p.join(dbDir, 'thumbnails')).existsSync(), isFalse);
  });

  test(
    'thumbnail key survives when generation finishes before the file row is inserted',
    () async {
      // Discovery enqueues the thumbnail job before the batch upsert flushes,
      // so the row may not exist yet when the job's UPDATE runs. Reproduce
      // that ordering against a real database and confirm the retry in
      // _enqueueThumbnailJob picks the key up once the row lands, instead of
      // the UPDATE silently affecting zero rows and losing it.
      final dbDir = io.Directory.systemTemp
          .createTempSync('thumb_race_db')
          .path;
      addTearDown(() => io.Directory(dbDir).deleteSync(recursive: true));

      final appDb = await AppDatabase.create(null, dbDir, 'race_test.db');
      addTearDown(() => appDb.close());

      final image = img.Image(width: 100, height: 100);
      img.fill(image, color: img.ColorRgb8(0, 0, 255));
      final path = p.join(tempDir, 'race.jpg');
      io.File(path).writeAsBytesSync(img.encodeJpg(image));

      final raceWorker = LocalFileIsolateWorker(
        null,
        mockPort,
        dbDir,
        'race_test.db',
        mockPort,
      );

      const fileId = 'race-file-id';

      // Thumbnail generation completes first: no file row exists yet.
      raceWorker.enqueueThumbnailJobForTesting(
        appDb,
        'test-collection-id',
        fileId,
        path,
        FilesConstants.mimeTypeImage,
        null,
      );

      // Give the job a head start so its first UPDATE attempt runs and
      // affects zero rows before the row is inserted below.
      await Future.delayed(const Duration(milliseconds: 50));

      await FileDesktopRepository(appDb).upsertAll([
        File(
          id: fileId,
          name: 'race.jpg',
          path: path,
          parent: tempDir,
          dateCreated: DateTime.now(),
          dateLastModified: DateTime.now(),
          collectionId: 'test-collection-id',
          contentType: FilesConstants.mimeTypeImage,
          size: io.File(path).lengthSync(),
          isDeleted: false,
        ),
      ]);

      // Wait for the queue to finish retrying and settle.
      final completer = Completer<void>();
      Timer.periodic(const Duration(milliseconds: 50), (timer) {
        if (raceWorker.queueLengthForTesting == 0 &&
            raceWorker.activeThumbnailJobsForTesting == 0) {
          timer.cancel();
          if (!completer.isCompleted) completer.complete();
        }
      });
      await completer.future.timeout(const Duration(seconds: 5));

      final rows = await appDb.select(
        'SELECT thumbnail FROM files WHERE id = ?',
        [fileId],
      );
      expect(rows, isNotEmpty);
      expect(rows.first['thumbnail'], isNotNull);
    },
  );
}
