import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';
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

  // The Locations drawer searches a place and filters on the GPS coordinates
  // EXIF already gave the photos. If the box is wrong the grid simply shows
  // the wrong pictures, which nothing else in the app would reveal.
  group('PhotosRepository place filter', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late PhotosRepository photos;

    // Austin, and points at increasing distance from it.
    const austin = PhotoPlaceFilter(
      label: 'Austin, Texas, United States',
      latitude: 30.26715,
      longitude: -97.74306,
    );

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_geo_');

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
          name: 'Local',
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

    Future<void> addPhoto(String name, {double? lat, double? lng}) async {
      await FileDesktopRepository(db).create(
        File(
          id: 'col-1:$name',
          name: name,
          path: name,
          parent: '',
          dateCreated: DateTime(2026, 5, 4),
          dateLastModified: DateTime(2026, 5, 4),
          collectionId: 'col-1',
          contentType: FilesConstants.mimeTypeImage,
          size: 3,
          isDeleted: false,
          isInline: false,
          latitude: lat,
          longitude: lng,
        ),
      );
    }

    test('keeps photos inside the radius and drops the ones outside', () async {
      await addPhoto('downtown.jpg', lat: 30.2672, lng: -97.7431); // ~0 km
      await addPhoto('round-rock.jpg', lat: 30.5083, lng: -97.6789); // ~28 km
      await addPhoto('houston.jpg', lat: 29.7604, lng: -95.3698); // ~235 km

      final names = (await photos.photos(
        filter: PhotoFilter(place: austin.copyWith(radiusMiles: 5)),
      )).map((f) => f.name).toSet();

      expect(names, {'downtown.jpg'});
    });

    test('the default radius covers a metro area, not just downtown', () async {
      // 25 miles. A default tight enough to exclude the next town over made
      // the filter look broken on libraries whose photos are spread across
      // one metro area — which is most of them.
      await addPhoto('downtown.jpg', lat: 30.2672, lng: -97.7431);
      await addPhoto('round-rock.jpg', lat: 30.5083, lng: -97.6789);
      await addPhoto('houston.jpg', lat: 29.7604, lng: -95.3698);

      final names = (await photos.photos(
        filter: const PhotoFilter(place: austin),
      )).map((f) => f.name).toSet();

      expect(names, {'downtown.jpg', 'round-rock.jpg'});
    });

    test('a wider radius reaches further out', () async {
      await addPhoto('downtown.jpg', lat: 30.2672, lng: -97.7431);
      await addPhoto('round-rock.jpg', lat: 30.5083, lng: -97.6789);
      await addPhoto('houston.jpg', lat: 29.7604, lng: -95.3698);

      final names = (await photos.photos(
        filter: PhotoFilter(place: austin.copyWith(radiusMiles: 250)),
      )).map((f) => f.name).toSet();

      expect(names, {'downtown.jpg', 'round-rock.jpg', 'houston.jpg'});
    });

    test('photos with no coordinates never match a place', () async {
      // Most libraries are largely untagged; a null latitude has to read as
      // "unknown", not as "matches whatever you searched".
      await addPhoto('scanned-print.jpg');
      await addPhoto('downtown.jpg', lat: 30.2672, lng: -97.7431);

      final names = (await photos.photos(
        filter: const PhotoFilter(place: austin),
      )).map((f) => f.name).toSet();

      expect(names, {'downtown.jpg'});
    });

    test('combines with the other filters rather than replacing them', () async {
      // Picking a city narrows what is already on screen — a location plus
      // Favorites has to mean both, or the drawer lies about its own state.
      await addPhoto('downtown.jpg', lat: 30.2672, lng: -97.7431);
      await addPhoto('downtown-fav.jpg', lat: 30.2680, lng: -97.7440);
      await db.execute("UPDATE files SET is_favorite = 1 WHERE id = ?", [
        'col-1:downtown-fav.jpg',
      ]);

      final names = (await photos.photos(
        filter: const PhotoFilter(place: austin, onlyFavorites: true),
      )).map((f) => f.name).toSet();

      expect(names, {'downtown-fav.jpg'});
    });

    test('a place spanning the antimeridian still matches both sides', () async {
      // Raw bounds run past +180 here. Written as a plain BETWEEN the range
      // inverts and matches nothing, so a Fiji search would look empty rather
      // than wrong.
      await addPhoto('suva.jpg', lat: -18.14, lng: 178.44);
      await addPhoto('east-of-line.jpg', lat: -18.20, lng: -179.60);
      await addPhoto('austin.jpg', lat: 30.2672, lng: -97.7431);

      final names = (await photos.photos(
        filter: const PhotoFilter(
          place: PhotoPlaceFilter(
            label: 'Suva, Fiji',
            latitude: -18.14,
            longitude: 178.44,
            radiusKm: 250,
          ),
        ),
      )).map((f) => f.name).toSet();

      expect(names, {'suva.jpg', 'east-of-line.jpg'});
    });
  });

  // Once mail attachments and scanned files share one grid, a photo on its own
  // says nothing about where it came from. sourceFor is what the info sidebar
  // shows instead of a raw collection id, and — for attachments — what gives it
  // a message id to link back to.
  group('PhotosRepository.sourceFor', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late PhotosRepository photos;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_src_');

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
          name: 'My Pictures',
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

      await db.execute(
        'INSERT INTO email_folders (id, collection_id, name, type,'
        ' messages_total, messages_unread) VALUES (?, ?, ?, ?, ?, ?)',
        ['Label_7', 'gmail-1', 'Holidays', 'user', 1, 0],
      );
      await db.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject,'
        ' folder_id, is_deleted) VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
        [
          'msg-1',
          'gmail-1',
          DateTime(2026, 5, 4).millisecondsSinceEpoch,
          'sender@example.com',
          'me@example.com',
          'Beach trip photos',
          'Label_7',
        ],
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

    Future<File> addFile(
      String id,
      String collectionId,
      String name, {
      String parent = '',
      String? emailId,
    }) async {
      final file = File(
        id: id,
        name: name,
        path: name,
        parent: parent,
        dateCreated: DateTime(2026, 5, 4),
        dateLastModified: DateTime(2026, 5, 4),
        collectionId: collectionId,
        contentType: FilesConstants.mimeTypeImage,
        size: 3,
        isDeleted: false,
        isInline: false,
        emailId: emailId,
      );
      await FileDesktopRepository(db).create(file);
      return file;
    }

    test('an email attachment resolves to collection/folder/subject', () async {
      final file = await addFile(
        'gmail-1:att.jpg',
        'gmail-1',
        'att.jpg',
        emailId: 'msg-1',
      );

      final source = await photos.sourceFor(file);

      expect(source!.path, 'Gmail (one@example.com)/Holidays/Beach trip photos');
      // The id is what lets the sidebar route to the message, so an attachment
      // that resolves without one is a link that cannot be built.
      expect(source.emailId, 'msg-1');
      expect(source.isEmail, isTrue);
    });

    test('a file resolves to collection/folder/filename.ext', () async {
      final file = await addFile(
        'local-1:sunset.jpg',
        'local-1',
        'sunset.jpg',
        parent: 'Trips/2026',
      );

      final source = await photos.sourceFor(file);

      expect(source!.path, 'My Pictures/Trips/2026/sunset.jpg');
      // Nothing to link to — the Files module is not where this row lives.
      expect(source.emailId, isNull);
    });

    test('a file at the collection root omits the folder segment', () async {
      final file = await addFile('local-1:root.jpg', 'local-1', 'root.jpg');

      final source = await photos.sourceFor(file);

      expect(source!.path, 'My Pictures/root.jpg');
    });

    test('an attachment whose message is gone falls back to the file', () async {
      // Deleting a mailbox drops the messages but their attachment rows can
      // outlive them; a link to a message that no longer exists is worse than
      // no link at all.
      final file = await addFile(
        'gmail-1:orphan.jpg',
        'gmail-1',
        'orphan.jpg',
        emailId: 'msg-gone',
      );

      final source = await photos.sourceFor(file);

      expect(source!.path, 'Gmail (one@example.com)/orphan.jpg');
      expect(source.emailId, isNull);
    });
  });
}
