import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/tag_chip.dart';
import 'package:mydatastudio/modules/photos/widgets/sidebar/info_sidebar.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/fake_tile_provider.dart';

class FakePhotosRepository extends PhotosRepository {
  List<String> tags = [];
  List<Album> albums = [];
  Set<String> fileAlbumIds = {};
  String? updatedFileName;
  bool isDeleted = false;
  String? addedTag;
  String? removedTag;

  @override
  Future<List<String>> getTagsForFile(String fileId) async => tags;

  @override
  Future<List<Album>> allAlbums() async => albums;

  @override
  Future<List<Album>> getAlbumsForFile(String fileId) async {
    return albums.where((a) => fileAlbumIds.contains(a.id)).toList();
  }

  @override
  Future<void> addTag(String fileId, String tag) async {
    addedTag = tag;
    if (!tags.contains(tag)) tags.add(tag);
  }

  @override
  Future<void> removeTag(String fileId, String tag) async {
    removedTag = tag;
    tags.remove(tag);
  }

  @override
  Future<File?> updateFileName(String fileId, String newName) async {
    updatedFileName = newName;
    return null;
  }

  @override
  Future<void> deleteFile(String fileId) async {
    isDeleted = true;
  }
}

File _createTestFile() {
  return File(
    id: 'f1',
    name: 'sunset_beach.jpg',
    path: '/photos/sunset_beach.jpg',
    parent: '/photos',
    dateCreated: DateTime(2026, 7, 15, 14, 30),
    dateLastModified: DateTime(2026, 7, 15, 14, 30),
    collectionId: 'col-photos',
    contentType: 'image/jpeg',
    size: 2457600, // ~2.3 MB
    isDeleted: false,
    latitude: 34.0522,
    longitude: -118.2437,
  );
}

Widget _buildTestableWidget(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(
      body: SizedBox(
        width: 320,
        height: 800,
        child: child,
      ),
    ),
  );
}

void main() {
  tearDown(() {
    ViewStateService.instance.setInfoMedia(null);
    ViewStateService.instance.isInfoOpen.add(false);
  });

  testWidgets('renders metadata for a given file', (WidgetTester tester) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);
    ViewStateService.instance.isInfoOpen.add(true);

    final fakeRepo = FakePhotosRepository();
    fakeRepo.tags = ['beach', 'sunset'];
    fakeRepo.albums = [Album(id: 'a1', name: 'Summer 2026')];

    await tester.pumpWidget(_buildTestableWidget(InfoSidebar(repository: fakeRepo)));
    await tester.pumpAndSettle();

    // Verify title and header
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('sunset_beach.jpg'), findsOneWidget);

    // Verify metadata rows
    expect(find.text('Information'), findsOneWidget);
    expect(find.text('Resolution'), findsOneWidget);
    expect(find.text('2.3 MB'), findsOneWidget);
    expect(find.text('image/jpeg'), findsOneWidget);
    expect(find.text('34.0522, -118.2437'), findsOneWidget);
    expect(find.text('col-photos'), findsOneWidget);

    // The standalone Delete and Open in Finder buttons were both removed;
    // deleting is still reachable via the keyboard shortcut and the
    // per-item action in the Similar tab.
    expect(find.text('Open in Finder'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('close button calls the close handler', (WidgetTester tester) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);
    ViewStateService.instance.isInfoOpen.add(true);

    final fakeRepo = FakePhotosRepository();

    await tester.pumpWidget(_buildTestableWidget(InfoSidebar(repository: fakeRepo)));
    await tester.pumpAndSettle();

    expect(ViewStateService.instance.isInfoOpen.value, isTrue);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(ViewStateService.instance.isInfoOpen.value, isFalse);
  });

  testWidgets('tag chips display correctly', (WidgetTester tester) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);

    final fakeRepo = FakePhotosRepository();
    fakeRepo.tags = ['nature', 'ocean'];

    await tester.pumpWidget(_buildTestableWidget(InfoSidebar(repository: fakeRepo)));
    await tester.pumpAndSettle();

    expect(find.text('Tags (2)'), findsOneWidget);
    expect(find.byType(TagChip), findsNWidgets(2));
    expect(find.text('#nature'), findsOneWidget);
    expect(find.text('#ocean'), findsOneWidget);
  });

  testWidgets('add tag input and button adds a new tag', (WidgetTester tester) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);

    final fakeRepo = FakePhotosRepository();

    await tester.pumpWidget(_buildTestableWidget(InfoSidebar(repository: fakeRepo)));
    await tester.pumpAndSettle();

    final tagInput = find.byType(TextField);
    await tester.enterText(tagInput, 'vacation');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(fakeRepo.addedTag, equals('vacation'));
    expect(find.text('#vacation'), findsOneWidget);
  });

  group('InfoSidebar EXIF/Location/Similar tabs', () {
    // These need a real DB-backed Collection: InfoSidebar resolves it via
    // CollectionRepository to feed TabbedMetadataSection (reused verbatim
    // from the Files module), the same section that used to be missing here.
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp(
        'mydatastudio_info_sidebar_',
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

      await CollectionRepository(db).addCollection(
        Collection(
          id: 'col-photos',
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
      ViewStateService.instance.setInfoMedia(null);
      ViewStateService.instance.isInfoOpen.add(false);
    });

    testWidgets(
      'shows EXIF, LOCATION, and SIMILAR tabs once the collection resolves',
      (WidgetTester tester) async {
        // Real file I/O — copying the fixture and InfoSidebar's own
        // readExifFromFile call during pumpWidget — has to run inside
        // runAsync. testWidgets bodies execute in a FakeAsync zone, and real
        // (non-Timer) I/O completions never arrive there, so calling this
        // directly hangs indefinitely instead of erroring.
        await tester.runAsync(() async {
          // Copy the GPS-tagged fixture into the temp collection dir so the
          // absolute path resolves to a real file on disk.
          final fixtureBytes = await io.File(
            'test/resources/gps-536x354.jpg',
          ).readAsBytes();
          final imgPath = p.join(tempDir.path, 'photo.jpg');
          await io.File(imgPath).writeAsBytes(fixtureBytes);

          final testFile = File(
            id: 'f1',
            name: 'photo.jpg',
            path: imgPath,
            parent: '',
            dateCreated: DateTime(2026, 7, 15),
            dateLastModified: DateTime(2026, 7, 15),
            collectionId: 'col-photos',
            contentType: 'image/jpeg',
            size: fixtureBytes.length,
            isDeleted: false,
          );

          ViewStateService.instance.setInfoMedia(testFile);
          ViewStateService.instance.isInfoOpen.add(true);

          final fakeRepo = FakePhotosRepository();

          await tester.pumpWidget(
            _buildTestableWidget(
              InfoSidebar(
                repository: fakeRepo,
                tileProvider: FakeMemoryTileProvider(),
              ),
            ),
          );
          // Let _loadCollection/_loadExif/_loadTagsAndAlbums's real DB and
          // file reads resolve on the real event loop.
          await Future.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();

        expect(find.text('EXIF'), findsOneWidget);
        expect(find.text('LOCATION'), findsOneWidget);
        expect(find.text('SIMILAR'), findsOneWidget);
      },
    );
  });
}
