import 'dart:io' as io;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/pages/rx_files_page.dart';
import 'package:mydatastudio/modules/photos/models/photo_source.dart';
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
  PhotoSource? source;

  @override
  Future<PhotoSource?> sourceFor(File file) async => source;

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
    home: Scaffold(body: SizedBox(width: 320, height: 800, child: child)),
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

    await tester.pumpWidget(
      _buildTestableWidget(InfoSidebar(repository: fakeRepo)),
    );
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

  testWidgets('close button calls the close handler', (
    WidgetTester tester,
  ) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);
    ViewStateService.instance.isInfoOpen.add(true);

    final fakeRepo = FakePhotosRepository();

    await tester.pumpWidget(
      _buildTestableWidget(InfoSidebar(repository: fakeRepo)),
    );
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

    await tester.pumpWidget(
      _buildTestableWidget(InfoSidebar(repository: fakeRepo)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tags (2)'), findsOneWidget);
    expect(find.byType(TagChip), findsNWidgets(2));
    expect(find.text('#nature'), findsOneWidget);
    expect(find.text('#ocean'), findsOneWidget);
  });

  testWidgets('add tag input and button adds a new tag', (
    WidgetTester tester,
  ) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);

    final fakeRepo = FakePhotosRepository();

    await tester.pumpWidget(
      _buildTestableWidget(InfoSidebar(repository: fakeRepo)),
    );
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

  // A photo pulled out of an email is indistinguishable from a scanned one in
  // the grid, so the Source row is the only thing that says which it is — and
  // for attachments, the only way back to the message that carried it.
  group('InfoSidebar source row', () {
    // A real router, because the trail's whole job is to navigate — a fake
    // callback would prove nothing about where the link actually goes.
    Future<void> pumpWith(WidgetTester tester, PhotoSource? source) async {
      ViewStateService.instance.setInfoMedia(_createTestFile());
      ViewStateService.instance.isInfoOpen.add(true);

      final fakeRepo = FakePhotosRepository()..source = source;
      final router = GoRouter(
        initialLocation: '/photos',
        routes: [
          GoRoute(
            path: '/photos',
            builder: (context, state) => Scaffold(
              body: SizedBox(
                width: 320,
                height: 800,
                child: InfoSidebar(repository: fakeRepo),
              ),
            ),
          ),
          GoRoute(
            path: '/files',
            builder: (context, state) => const Scaffold(body: Text('Files')),
          ),
          GoRoute(
            path: '/email',
            builder: (context, state) => const Scaffold(body: Text('Email')),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders a file as a link to its folder in Files', (
      tester,
    ) async {
      await pumpWith(
        tester,
        const PhotoSource(
          collectionName: 'My Pictures',
          folder: 'Trips/2026',
          leaf: 'sunset_beach.jpg',
        ),
      );

      expect(
        find.text('My Pictures/Trips/2026/sunset_beach.jpg'),
        findsOneWidget,
      );
      // A folder, not an envelope — the two destinations are different
      // modules and the icon is what says which.
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      expect(find.byIcon(Icons.email_outlined), findsNothing);
      expect(find.byTooltip('Show this file in Files'), findsOneWidget);
    });

    testWidgets('tapping a file routes to Files and queues the file', (
      tester,
    ) async {
      RxFilesPage.openFileRequest.add(null);
      addTearDown(() => RxFilesPage.openFileRequest.add(null));

      await pumpWith(
        tester,
        const PhotoSource(
          collectionName: 'My Pictures',
          folder: 'Trips/2026',
          leaf: 'sunset_beach.jpg',
        ),
      );

      await tester.tap(find.byTooltip('Show this file in Files'));
      await tester.pumpAndSettle();

      expect(find.text('Files'), findsOneWidget);
      // Queued rather than handed over by the route: RxFilesPage subscribes
      // when it mounts, which is after this tap has already navigated.
      expect(RxFilesPage.openFileRequest.value?.id, 'f1');
    });

    testWidgets('renders an attachment as a link to its message', (
      tester,
    ) async {
      await pumpWith(
        tester,
        const PhotoSource(
          collectionName: 'Gmail (me@example.com)',
          folder: 'Holidays',
          leaf: 'Beach trip photos',
          emailId: 'msg-1',
        ),
      );

      expect(
        find.text('Gmail (me@example.com)/Holidays/Beach trip photos'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.email_outlined), findsOneWidget);
      expect(
        find.byTooltip('Open this email'),
        findsOneWidget,
        reason: 'the trail has to read as clickable, not as plain metadata',
      );
    });

    testWidgets('falls back to the collection id until the source resolves', (
      tester,
    ) async {
      await pumpWith(tester, null);

      expect(find.text('col-photos'), findsOneWidget);
    });
  });
}
