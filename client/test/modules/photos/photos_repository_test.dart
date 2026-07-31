import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// The scanners do not agree on how they spell "this is an image". Gmail keeps
/// the real MIME type on the row (`image/jpeg`); the local, Drive, Yahoo,
/// Outlook and PST scanners store the app's coarse category
/// (`application/image`). The photo grid has to accept both, or an entire
/// source silently has no pictures — no error, no empty state that explains
/// itself, just a grid that never shows the user's Gmail photos.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PhotosRepository image matching', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late PhotosRepository photos;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_photos_');

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
      photos = PhotosRepository();

      await CollectionRepository(db).addCollection(
        Collection(
          id: 'col-1',
          name: 'Test',
          path: tempDir.path,
          type: 'email',
          scanner: 'gmail',
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

    Future<void> addFile(
      String name,
      String contentType, {
      bool isInline = false,
    }) async {
      await FileDesktopRepository(db).create(
        File(
          id: 'col-1:$name',
          name: name,
          path: name,
          parent: '',
          dateCreated: DateTime.now(),
          dateLastModified: DateTime.now(),
          collectionId: 'col-1',
          contentType: contentType,
          size: 3,
          isDeleted: false,
          isInline: isInline,
        ),
      );
    }

    test('accepts both the coarse category and a real image MIME type',
        () async {
      await addFile('scanned.jpg', FilesConstants.mimeTypeImage);
      await addFile('gmail-attachment.jpg', 'image/jpeg');
      await addFile('gmail-attachment.png', 'image/png');
      await addFile('report.pdf', FilesConstants.mimeTypePdf);
      await addFile('notes.txt', FilesConstants.mimeTypeUnKnown);

      final names = (await photos.photos()).map((f) => f.name).toSet();

      expect(names, {
        'scanned.jpg',
        'gmail-attachment.jpg',
        'gmail-attachment.png',
      });
    });

    test('still excludes inline body images regardless of spelling', () async {
      await addFile('real-photo.jpg', 'image/jpeg');
      await addFile('tracking-pixel.gif', 'image/gif', isInline: true);
      await addFile('spacer.png', FilesConstants.mimeTypeImage, isInline: true);

      final names = (await photos.photos()).map((f) => f.name).toSet();

      expect(names, {'real-photo.jpg'});
    });

    test('photosByDate applies the same matching', () async {
      await addFile('scanned.jpg', FilesConstants.mimeTypeImage);
      await addFile('gmail-attachment.jpg', 'image/jpeg');
      await addFile('report.pdf', FilesConstants.mimeTypePdf);

      final grouped = await photos.photosByDate();
      final names = grouped.values.expand((f) => f).map((f) => f.name).toSet();

      expect(names, {'scanned.jpg', 'gmail-attachment.jpg'});
    });
  });
}
