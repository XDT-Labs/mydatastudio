import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/models/photo_section.dart';
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
      DateTime? dateCreated,
    }) async {
      await FileDesktopRepository(db).create(
        File(
          id: 'col-1:$name',
          name: name,
          path: name,
          parent: '',
          dateCreated: dateCreated ?? DateTime.now(),
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

  group('PhotosRepository lazy timeline queries', () {
    // These exist so the timeline/grid/list/map views never have to
    // materialize a user's whole library in memory: the DB groups and
    // paginates instead of Dart sorting an in-memory List<File> on every
    // rebuild (see photo_timeline_view.dart's old _groupAndSortFiles).
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late PhotosRepository photos;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp(
        'mydatastudio_photos_lazy_',
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
      photos = PhotosRepository();

      await CollectionRepository(db).addCollection(
        Collection(
          id: 'col-1',
          name: 'Test',
          path: tempDir.path,
          type: 'local',
          scanner: 'local',
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

    Future<void> addFile(String name, DateTime dateCreated) async {
      await FileDesktopRepository(db).create(
        File(
          id: 'col-1:$name',
          name: name,
          path: name,
          parent: '',
          dateCreated: dateCreated,
          dateLastModified: dateCreated,
          collectionId: 'col-1',
          contentType: FilesConstants.mimeTypeImage,
          size: 3,
          isDeleted: false,
          isInline: false,
        ),
      );
    }

    test('dateRange reports the min, max and total across all matches', () async {
      await addFile('a.jpg', DateTime(2016, 1, 5));
      await addFile('b.jpg', DateTime(2020, 6, 15));
      await addFile('c.jpg', DateTime(2026, 4, 30));

      final range = await photos.dateRange();

      expect(range.min, DateTime(2016, 1, 5));
      expect(range.max, DateTime(2026, 4, 30));
      expect(range.total, 3);
    });

    test('sectionSummaries buckets by month and counts each bucket', () async {
      await addFile('apr-1.jpg', DateTime(2026, 4, 3));
      await addFile('apr-2.jpg', DateTime(2026, 4, 20));
      await addFile('mar-1.jpg', DateTime(2026, 3, 10));

      final sections = await photos.sectionSummaries(
        granularity: PhotoSectionGranularity.month,
      );

      expect(sections.map((s) => s.bucketKey), ['2026-04', '2026-03']);
      expect(sections.map((s) => s.count), [2, 1]);
    });

    test('sectionSummaries buckets by year when granularity is year', () async {
      await addFile('y2026.jpg', DateTime(2026, 4, 3));
      await addFile('y2020-a.jpg', DateTime(2020, 6, 15));
      await addFile('y2020-b.jpg', DateTime(2020, 11, 2));

      final sections = await photos.sectionSummaries(
        granularity: PhotoSectionGranularity.year,
      );

      expect(sections.map((s) => s.bucketKey), ['2026', '2020']);
      expect(sections.map((s) => s.count), [1, 2]);
    });

    test('photosInBucket returns only files from that bucket, paginated', () async {
      await addFile('apr-1.jpg', DateTime(2026, 4, 1));
      await addFile('apr-2.jpg', DateTime(2026, 4, 2));
      await addFile('apr-3.jpg', DateTime(2026, 4, 3));
      await addFile('mar-1.jpg', DateTime(2026, 3, 1));

      final firstPage = await photos.photosInBucket(
        granularity: PhotoSectionGranularity.month,
        bucketKey: '2026-04',
        limit: 2,
        offset: 0,
      );
      final secondPage = await photos.photosInBucket(
        granularity: PhotoSectionGranularity.month,
        bucketKey: '2026-04',
        limit: 2,
        offset: 2,
      );

      expect(firstPage.map((f) => f.name), ['apr-3.jpg', 'apr-2.jpg']);
      expect(secondPage.map((f) => f.name), ['apr-1.jpg']);
    });

    test('photosPage pages through results without duplicates or gaps', () async {
      for (var i = 1; i <= 5; i++) {
        await addFile('$i.jpg', DateTime(2026, 1, i));
      }

      final firstPage = await photos.photosPage(limit: 2, offset: 0);
      final secondPage = await photos.photosPage(limit: 2, offset: 2);
      final thirdPage = await photos.photosPage(limit: 2, offset: 4);

      final allNames = [
        ...firstPage,
        ...secondPage,
        ...thirdPage,
      ].map((f) => f.name).toList();

      expect(allNames, ['5.jpg', '4.jpg', '3.jpg', '2.jpg', '1.jpg']);
    });
  });

  group('PhotosRepository collection filtering', () {
    // The Photos sidebar's Sources list filters by collection (a single
    // collection when a user clicks one account, a group of collections
    // when they click a source-type header). This used to filter on
    // `c.type`, a column that only ever holds 'file'/'email'/etc — never
    // the scanner-derived values ('local', 'gdrive', ...) the sidebar sent,
    // so the filter silently matched nothing.
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late PhotosRepository photos;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp(
        'mydatastudio_photos_collections_',
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
      photos = PhotosRepository();

      await CollectionRepository(db).addCollection(
        Collection(
          id: 'local-1',
          name: 'Local',
          path: tempDir.path,
          type: 'file',
          scanner: 'file.local',
          scanStatus: 'idle',
          needsReAuth: false,
          localCopyPath: tempDir.path,
        ),
      );
      await CollectionRepository(db).addCollection(
        Collection(
          id: 'gmail-1',
          name: 'Gmail (one@example.com)',
          path: tempDir.path,
          type: 'email',
          scanner: 'email.gmail',
          scanStatus: 'idle',
          needsReAuth: false,
          localCopyPath: tempDir.path,
        ),
      );
      await CollectionRepository(db).addCollection(
        Collection(
          id: 'gmail-2',
          name: 'Gmail (two@example.com)',
          path: tempDir.path,
          type: 'email',
          scanner: 'email.gmail',
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

    Future<void> addFile(String collectionId, String name) async {
      await FileDesktopRepository(db).create(
        File(
          id: '$collectionId:$name',
          name: name,
          path: name,
          parent: '',
          dateCreated: DateTime.now(),
          dateLastModified: DateTime.now(),
          collectionId: collectionId,
          contentType: FilesConstants.mimeTypeImage,
          size: 3,
          isDeleted: false,
          isInline: false,
        ),
      );
    }

    test('collectionId filters to a single collection', () async {
      await addFile('local-1', 'a.jpg');
      await addFile('gmail-1', 'b.jpg');
      await addFile('gmail-2', 'c.jpg');

      final names = (await photos.photos(
        filter: const PhotoFilter(collectionId: 'gmail-1'),
      )).map((f) => f.name).toSet();

      expect(names, {'b.jpg'});
    });

    test('collectionIds filters to every collection in the list', () async {
      await addFile('local-1', 'a.jpg');
      await addFile('gmail-1', 'b.jpg');
      await addFile('gmail-2', 'c.jpg');

      final names = (await photos.photos(
        filter: const PhotoFilter(collectionIds: ['gmail-1', 'gmail-2']),
      )).map((f) => f.name).toSet();

      expect(names, {'b.jpg', 'c.jpg'});
    });
  });
}
