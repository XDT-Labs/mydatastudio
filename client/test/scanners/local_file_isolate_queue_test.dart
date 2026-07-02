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
    worker = LocalFileIsolateWorker(
      null,
      mockPort,
      '/tmp',
      'test.db',
      mockPort,
    );
    tempDir = io.Directory.systemTemp.createTempSync('thumb_queue_test').path;
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
}
