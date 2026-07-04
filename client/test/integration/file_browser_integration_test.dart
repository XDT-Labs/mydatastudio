import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/pages/rx_files_page.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/repositories/user_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/services/get_user_service.dart';
import 'package:mydatastudio/modules/files/services/get_files_and_folders_service.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:uuid/uuid.dart';
import 'package:rxdart/rxdart.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';
import 'package:mydatastudio/modules/files/widgets/file_drawer.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/files/notifications/path_changed_notification.dart';
import 'package:mydatastudio/modules/files/notifications/file_notification.dart';
import 'package:mydatastudio/models/tables/file_asset.dart';
import 'package:mydatastudio/modules/files/widgets/file_table.dart';
import 'package:mocktail/mocktail.dart';

class MockPathProviderPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {}

void main() {
  late io.Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    // 0. Reset singleton services and subjects
    GetCollectionsService.instance.reset();
    GetFileAndFoldersService.instance.reset();
    RxFilesPage.selectedCollection = PublishSubject();
    RxFilesPage.selectedPath = PublishSubject();
    ScannerManager.getInstance().scannerFactory = null;

    // 1. Create a clean temporary directory for each test
    tempDir = await io.Directory.systemTemp.createTemp(
      'file_browser_integration_test',
    );

    // 2. Create the data directory for SQLite
    final dataDir = io.Directory(p.join(tempDir.path, 'data'));
    await dataDir.create(recursive: true);

    // 3. Create config.json that DatabaseManager expects
    final configFile = io.File(
      p.join(tempDir.path, AppConstants.configFileName),
    );
    await configFile.writeAsString(jsonEncode({'path': tempDir.path}));

    // 4. Mock PathProvider so DatabaseManager finds our config.json
    final mockPathProvider = MockPathProviderPlatform();
    PathProviderPlatform.instance = mockPathProvider;

    when(
      () => mockPathProvider.getApplicationSupportPath(),
    ).thenAnswer((_) async => tempDir.path);
    when(
      () => mockPathProvider.getTemporaryPath(),
    ).thenAnswer((_) async => tempDir.path);
    when(
      () => mockPathProvider.getApplicationDocumentsPath(),
    ).thenAnswer((_) async => tempDir.path);
    when(
      () => mockPathProvider.getLibraryPath(),
    ).thenAnswer((_) async => tempDir.path);

    // 5. Set test flags
    DatabaseManager.skipExtensionLoading = true;
    DatabaseManager.isTesting = true;

    // 6. Initialize DatabaseManager
    final dbMgr = DatabaseManager.instance;
    db = await dbMgr.initializeDatabase();

    // 7. Mock LLM service URL to avoid initialization errors
    MainApp.llmServiceUrl.add('http://localhost:8000');
  });

  tearDown(() async {
    ScannerManager.getInstance().stopScanners();
    final dbMgr = DatabaseManager.instance;
    dbMgr.dispose();

    // Give isolates a moment to exit
    await Future.delayed(const Duration(milliseconds: 500));

    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (e) {
        print("Warning: Could not delete temp directory: $e");
      }
    }
  });

  testWidgets('Full Circuit Integration Test: Scan -> DB -> UI', (
    WidgetTester tester,
  ) async {
    final colId = 'integration-test-col';
    final collectionPath = p.join(tempDir.path, 'test_files');
    io.Directory(collectionPath).createSync();

    // Set a desktop size to avoid overflows
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    // Setup a fake user and insert via runAsync
    final user = AppUser(
      id: const Uuid().v4(),
      name: 'Integration Test User',
      email: 'test@example.com',
      password: 'password',
      localStoragePath: tempDir.path,
    );

    await tester.runAsync(() async {
      final dbMgr = DatabaseManager.instance;
      final userRepo = UserRepository(dbMgr.database!);
      await userRepo.saveUser(user);
    });

    // Seed the GetUserService singleton
    GetUserService.instance.sink.add(user);
    DatabaseManager.isInitializedNotifier.value = true;

    // 1. Create a collection in DB
    final colRepo = CollectionRepository(DatabaseManager.instance.database!);
    await tester.runAsync(() async {
      await colRepo.addCollection(
        Collection(
          id: colId,
          name: 'Integration Collection',
          path: collectionPath,
          type: 'local',
          scanner: AppConstants.scannerFileLocal,
          scanStatus: 'idle',
          needsReAuth: false,
        ),
      );
    });

    // 2. Seed test files on disk
    io.File(p.join(collectionPath, 'test1.txt')).createSync();
    io.File(p.join(collectionPath, 'test2.txt')).createSync();
    io.Directory(p.join(collectionPath, 'subdir')).createSync();
    io.File(p.join(collectionPath, 'subdir', 'test3.txt')).createSync();

    print('Test: Files seeded in $collectionPath');

    // 3. Trigger Scanner
    final scannerManager = ScannerManager(db);
    late Collection collection;

    await tester.runAsync(() async {
      final fetchedCollection = await colRepo.collectionById(colId);
      expect(fetchedCollection, isNotNull);
      collection = fetchedCollection!;
    });

    print('Test: Starting scanner for ${collection.name}');
    await tester.runAsync(() async {
      await scannerManager.startScanner(collection);
    });
    print('Test: scanner.start() finished in test');

    // 4. Wait for database persistence
    print('Test: Waiting for files to reach DB...');
    final fileRepo = FileDesktopRepository(DatabaseManager.instance.database!);
    await tester.runAsync(() async {
      int retries = 0;
      int count = 0;
      while (retries < 40) {
        final files = await fileRepo.getByParentPath(colId, '');
        count = files.length;
        print('Test: DB file count = $count');
        if (count >= 2) break;
        await Future.delayed(const Duration(milliseconds: 500));
        retries++;
      }
      expect(
        count,
        greaterThanOrEqualTo(2),
        reason: 'Should have found at least 2 files in root',
      );
    });

    await tester.runAsync(() async {
      final collectionsInDb = await colRepo.collections();
      print('Test: Collections in DB = ${collectionsInDb.length}');
      if (collectionsInDb.isNotEmpty) {
        print('Test: First collection name = ${collectionsInDb.first.name}');
      }

      // Let's seed GetCollectionsService manually to avoid timing issues
      GetCollectionsService.instance.sink.add(collectionsInDb);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RxFilesPage())),
      );

      // We need to set the selected collection for RxFilesPage AFTER pumpWidget (so it's listening)
      RxFilesPage.selectedCollection.add(collection);

      // Allow data to load and UI to settle dynamically
      int pumpRetries = 0;
      while (pumpRetries < 40) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.text('test1.txt').evaluate().isNotEmpty) {
          print('Test: Found test1.txt in widget tree at retry $pumpRetries!');
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
        pumpRetries++;
      }
    });

    // Print all rendered Text widgets for diagnostics
    for (final element in find.byType(Text).evaluate()) {
      final textWidget = element.widget as Text;
      print('Rendered Text: "${textWidget.data}"');
    }

    // Verify file names are present in the list
    expect(find.text('test1.txt'), findsOneWidget);
    expect(find.text('test2.txt'), findsOneWidget);
    expect(find.text('subdir'), findsOneWidget);

    print('Test: Integration test passed!');
  });

  testWidgets(
    'Lightroom full-screen preview toggling via Space and Escape keys',
    (WidgetTester tester) async {
      final colId = 'integration-test-col';
      final collectionPath = p.join(tempDir.path, 'test_files');
      io.Directory(collectionPath).createSync();

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final user = AppUser(
        id: const Uuid().v4(),
        name: 'Integration Test User',
        email: 'test@example.com',
        password: 'password',
        localStoragePath: tempDir.path,
      );

      await tester.runAsync(() async {
        final dbMgr = DatabaseManager.instance;
        final userRepo = UserRepository(dbMgr.database!);
        await userRepo.saveUser(user);
      });

      GetUserService.instance.sink.add(user);
      DatabaseManager.isInitializedNotifier.value = true;

      final colRepo = CollectionRepository(DatabaseManager.instance.database!);
      await tester.runAsync(() async {
        await colRepo.addCollection(
          Collection(
            id: colId,
            name: 'Integration Collection',
            path: collectionPath,
            type: 'local',
            scanner: AppConstants.scannerFileLocal,
            scanStatus: 'idle',
            needsReAuth: false,
          ),
        );
      });

      // Seed test files
      io.File(p.join(collectionPath, 'test1.txt')).createSync();
      io.File(p.join(collectionPath, 'image.png')).createSync();

      final scannerManager = ScannerManager(db);
      late Collection collection;

      await tester.runAsync(() async {
        final fetchedCollection = await colRepo.collectionById(colId);
        collection = fetchedCollection!;
        await scannerManager.startScanner(collection);
      });

      // Wait for database persistence
      final fileRepo = FileDesktopRepository(
        DatabaseManager.instance.database!,
      );
      await tester.runAsync(() async {
        int retries = 0;
        int count = 0;
        while (retries < 40) {
          final files = await fileRepo.getByParentPath(colId, '');
          count = files.length;
          print('Second Test: DB file count inside wait loop = $count');
          if (count >= 2) break;
          await Future.delayed(const Duration(milliseconds: 500));
          retries++;
        }
        expect(
          count,
          greaterThanOrEqualTo(2),
          reason: 'Should have found at least 2 files in root',
        );
      });

      await tester.runAsync(() async {
        final collectionsInDb = await colRepo.collections();
        GetCollectionsService.instance.sink.add(collectionsInDb);

        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: RxFilesPage())),
        );

        RxFilesPage.selectedCollection.add(collection);

        // Wait for files to load in UI
        int pumpRetries = 0;
        while (pumpRetries < 40) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.text('image.png').evaluate().isNotEmpty) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          pumpRetries++;
        }
      });

      // Diagnostics print
      for (final element in find.byType(Text).evaluate()) {
        final textWidget = element.widget as Text;
        print('Rendered Text in Test 2: "${textWidget.data}"');
      }

      // 1. Verify drawer starts closed and lightbox doesn't exist
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.text('File Details'), findsNothing);

      // 2. Select file (image.png) to open details drawer
      await tester.tap(find.text('image.png'));
      await tester.pumpAndSettle();

      // Details drawer should now be open
      expect(find.text('File Details'), findsOneWidget);

      // 3. Press Space bar -> Lightbox should open
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      // Verify lightbox is open
      expect(find.byTooltip('Close Preview (Esc)'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);

      // 4. Press Space bar again -> Lightbox should close
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close Preview (Esc)'), findsNothing);

      // 5. Press Space bar -> Lightbox open
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close Preview (Esc)'), findsOneWidget);

      // 6. Press Escape key -> Lightbox close
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close Preview (Esc)'), findsNothing);

      // 7. Test focus interaction: when input is focused, space bar does NOT open lightbox
      final focusNode = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Focus(
                  focusNode: focusNode,
                  child: EditableText(
                    controller: TextEditingController(),
                    focusNode: FocusNode(),
                    style: const TextStyle(),
                    cursorColor: Colors.black,
                    backgroundCursorColor: Colors.black,
                  ),
                ),
                const RxFilesPage(),
              ],
            ),
          ),
        ),
      );
      RxFilesPage.selectedCollection.add(collection);
      await tester.pump(const Duration(milliseconds: 500));

      // Select image.png again
      await tester.tap(find.text('image.png'));
      await tester.pump(const Duration(milliseconds: 500));

      // Focus the text field
      focusNode.requestFocus();
      await tester.pump();

      // Press space bar -> Lightbox should NOT open because input is focused!
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byTooltip('Close Preview (Esc)'), findsNothing);
    },
  );

  testWidgets(
    'Automatic folder scans on source addition, opening source, and folder navigation',
    (WidgetTester tester) async {
      final colId = 'scan-test-col';
      final collectionPath = p.join(tempDir.path, 'scan_test_files');
      io.Directory(collectionPath).createSync();

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // 1. Setup a fake scanner
      final fakeScanner = FakeCollectionScanner();
      ScannerManager.getInstance().scannerFactory = (col) async => fakeScanner;

      final collection = Collection(
        id: colId,
        name: 'Scan Test Collection',
        path: collectionPath,
        type: 'file',
        scanner: AppConstants.scannerFileLocal,
        scanStatus: 'idle',
        needsReAuth: false,
      );

      // Insert the collection into the DB so that GetCollectionsService.invoke finds it
      final colRepo = CollectionRepository(DatabaseManager.instance.database!);
      await tester.runAsync(() async {
        await colRepo.addCollection(collection);
        await ScannerManager.getInstance().registerScanner(collection);
      });

      // We need to seed GetCollectionsService manually
      GetCollectionsService.instance.sink.add([collection]);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  const SizedBox(width: 260, child: FileDrawer()),
                  const Expanded(child: RxFilesPage()),
                ],
              ),
            ),
          ),
        );

        // Verify that selecting the collection/opening source triggers a shallow scan
        RxFilesPage.selectedCollection.add(collection);
        
        // Allow data to load and UI to settle dynamically
        int pumpRetries = 0;
        while (pumpRetries < 40) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(FileTable).evaluate().isNotEmpty) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          pumpRetries++;
        }

        expect(fakeScanner.startCalls.length, greaterThanOrEqualTo(1));
        final openSourceCall = fakeScanner.startCalls.first;
        expect(openSourceCall['recursive'], isFalse);
        expect(openSourceCall['force'], isTrue);
        expect(openSourceCall['path'], equals(collectionPath));

        fakeScanner.startCalls.clear();

        // Verify that navigation (PathChangedNotification) triggers a shallow scan
        final subFolder = Folder(
          id: 'subfolder-id',
          name: 'Sub Folder',
          path: 'subdir',
          parent: '',
          dateCreated: DateTime.now(),
          dateLastModified: DateTime.now(),
          lastScannedDate: DateTime.now(),
          collectionId: colId,
        );

        // Dispatch path changed notification
        try {
          final element = tester.element(find.byType(FileTable));
          PathChangedNotification(subFolder, 'name', true).dispatch(element);
        } catch (e, stack) {
          print("Exception finding/dispatching: $e\n$stack");
        }
        await tester.pump(const Duration(milliseconds: 100));

        expect(fakeScanner.startCalls.length, greaterThanOrEqualTo(1));
        final navCall = fakeScanner.startCalls.first;
        expect(navCall['recursive'], isFalse);
        expect(navCall['force'], isTrue);
        expect(navCall['path'], equals(p.join(collectionPath, 'subdir')));

        // Verify clicking Sync in the sidebar triggers a full recursive scan
        fakeScanner.startCalls.clear();

        // Find and tap the trailing popup menu button on the ListTile
        final moreVertIcon = find.byIcon(Icons.more_vert);
        expect(moreVertIcon, findsOneWidget);
        await tester.tap(moreVertIcon);
        
        // Pump frames to let the popup menu open animation finish completely
        for (int i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // Tap the "Sync" popup menu item
        final syncMenuOption = find.text('Sync');
        expect(syncMenuOption, findsOneWidget);
        await tester.tap(syncMenuOption);
        
        // Pump frames to let the popup menu close animation finish completely and trigger onSync
        for (int i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // Wait for scan to trigger
        int syncRetries = 0;
        while (syncRetries < 40) {
          await tester.pump(const Duration(milliseconds: 100));
          if (fakeScanner.startCalls.isNotEmpty) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 50));
          syncRetries++;
        }

        expect(fakeScanner.startCalls.length, greaterThanOrEqualTo(1));
        final syncCall = fakeScanner.startCalls.first;
        expect(syncCall['recursive'], isTrue);
        expect(syncCall['force'], isTrue);
        expect(syncCall['path'], isNull); // Full sync has path == null
      });
    },
  );

  testWidgets(
    'Details drawer closes when more than 1 file is selected',
    (WidgetTester tester) async {
      final colId = 'integration-test-col';
      final collectionPath = p.join(tempDir.path, 'test_files');
      io.Directory(collectionPath).createSync();

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final user = AppUser(
        id: const Uuid().v4(),
        name: 'Integration Test User',
        email: 'test@example.com',
        password: 'password',
        localStoragePath: tempDir.path,
      );

      await tester.runAsync(() async {
        final dbMgr = DatabaseManager.instance;
        final userRepo = UserRepository(dbMgr.database!);
        await userRepo.saveUser(user);
      });

      GetUserService.instance.sink.add(user);
      DatabaseManager.isInitializedNotifier.value = true;

      final colRepo = CollectionRepository(DatabaseManager.instance.database!);
      await tester.runAsync(() async {
        await colRepo.addCollection(
          Collection(
            id: colId,
            name: 'Integration Collection',
            path: collectionPath,
            type: 'local',
            scanner: AppConstants.scannerFileLocal,
            scanStatus: 'idle',
            needsReAuth: false,
          ),
        );
      });

      // Seed test files
      io.File(p.join(collectionPath, 'image1.png')).createSync();
      io.File(p.join(collectionPath, 'image2.png')).createSync();

      final scannerManager = ScannerManager(db);
      late Collection collection;

      await tester.runAsync(() async {
        final fetchedCollection = await colRepo.collectionById(colId);
        collection = fetchedCollection!;
        await scannerManager.startScanner(collection);
      });

      // Wait for database persistence
      final fileRepo = FileDesktopRepository(
        DatabaseManager.instance.database!,
      );
      await tester.runAsync(() async {
        int retries = 0;
        int count = 0;
        while (retries < 40) {
          final files = await fileRepo.getByParentPath(colId, '');
          count = files.length;
          if (count >= 2) break;
          await Future.delayed(const Duration(milliseconds: 500));
          retries++;
        }
        expect(count, greaterThanOrEqualTo(2));
      });

      late List<FileAsset> dbFiles;
      await tester.runAsync(() async {
        dbFiles = await fileRepo.getByParentPath(colId, '');
      });

      await tester.runAsync(() async {
        final collectionsInDb = await colRepo.collections();
        GetCollectionsService.instance.sink.add(collectionsInDb);

        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: RxFilesPage())),
        );

        RxFilesPage.selectedCollection.add(collection);

        // Wait for files to load in UI
        int pumpRetries = 0;
        while (pumpRetries < 40) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.text('image1.png').evaluate().isNotEmpty) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          pumpRetries++;
        }
      });

      // 1. Verify drawer starts closed
      expect(find.text('File Details'), findsNothing);

      // 2. Select file (image1.png) to open details drawer
      await tester.tap(find.text('image1.png'));
      await tester.pumpAndSettle();

      // Details drawer should now be open
      expect(find.text('File Details'), findsOneWidget);

      // 3. Dispatch SelectionChangedNotification with 2 items (more than 1 item)
      final element = tester.element(find.byType(FileTable));
      SelectionChangedNotification(dbFiles).dispatch(element);
      await tester.pumpAndSettle();

      // Verify details drawer is closed because more than 1 file is selected
      expect(find.text('File Details'), findsNothing);
    },
  );
}

class FakeCollectionScanner extends CollectionScanner {
  final List<Map<String, dynamic>> startCalls = [];

  @override
  Future<int> start(
    Collection collection,
    String? path,
    bool recursive,
    bool force,
  ) async {
    startCalls.add({
      'collection': collection,
      'path': path,
      'recursive': recursive,
      'force': force,
    });
    return 0;
  }
}
