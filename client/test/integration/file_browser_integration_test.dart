import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/modules/files/pages/rx_files_page.dart';
import 'package:path/path.dart' as p;
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/services/get_user_service.dart';
import 'package:uuid/uuid.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/app_constants.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:mocktail/mocktail.dart';
import 'package:drift/drift.dart';

class MockPathProviderPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {}

void main() {
  late io.Directory tempDir;
  late AppDatabase db;

  setUp(() async {
    // 1. Create a clean temporary directory for each test
    tempDir = await io.Directory.systemTemp.createTemp('file_browser_integration_test');
    
    // 2. Create the data directory for SQLite
    final dataDir = io.Directory(p.join(tempDir.path, 'data'));
    await dataDir.create(recursive: true);
    
    // 3. Create config.json that DatabaseManager expects
    final configFile = io.File(p.join(tempDir.path, AppConstants.configFileName));
    await configFile.writeAsString(jsonEncode({'path': tempDir.path}));
    
    // 4. Mock PathProvider so DatabaseManager finds our config.json
    final mockPathProvider = MockPathProviderPlatform();
    PathProviderPlatform.instance = mockPathProvider;
    
    when(() => mockPathProvider.getApplicationSupportPath())
        .thenAnswer((_) async => tempDir.path);
    when(() => mockPathProvider.getTemporaryPath())
        .thenAnswer((_) async => tempDir.path);
    when(() => mockPathProvider.getApplicationDocumentsPath())
        .thenAnswer((_) async => tempDir.path);
    when(() => mockPathProvider.getLibraryPath())
        .thenAnswer((_) async => tempDir.path);

    // 5. Set test flags
    DatabaseManager.skipExtensionLoading = true;
    DatabaseManager.isTesting = true;

    // 6. Initialize DatabaseManager
    final dbMgr = DatabaseManager.instance;
    db = await dbMgr.initializeDatabase();
    
    // 7. Mock LLM service URL to avoid initialization errors
    MainApp.llmServiceUrl.add('http://localhost:8000');
    
    // 8. Setup a fake user
    final user = AppUser(
      id: const Uuid().v4(),
      name: 'Integration Test User',
      email: 'test@example.com',
      password: 'password',
      localStoragePath: tempDir.path,
    );
    
    // Insert user via directly to ensure it's synced
    await (dbMgr.database as AppDatabase).into((dbMgr.database as AppDatabase).appUsers).insert(
          AppUsersCompanion.insert(
            id: user.id,
            name: user.name,
            email: user.email,
            password: user.password,
            localStoragePath: user.localStoragePath,
          ),
        );
    
    // Seed the GetUserService singleton
    GetUserService.instance.sink.add(user);
    
    DatabaseManager.isInitializedNotifier.value = true;
  });

  tearDown(() async {
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

  testWidgets('Full Circuit Integration Test: Scan -> DB -> UI', (WidgetTester tester) async {
    final colId = 'integration-test-col';
    final collectionPath = p.join(tempDir.path, 'test_files');
    io.Directory(collectionPath).createSync();
    
    // Set a desktop size to avoid overflows
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    // 1. Create a collection in DB
    await db.into(db.collections).insert(
      CollectionsCompanion.insert(
        id: colId,
        name: 'Integration Collection',
        path: collectionPath,
        type: 'local',
        scanner: AppConstants.scannerFileLocal,
        scanStatus: 'idle',
        needsReAuth: false,
        downloadLocalCopy: const Value(false),
      ),
    );

    // 2. Seed test files on disk
    io.File(p.join(collectionPath, 'test1.txt')).createSync();
    io.File(p.join(collectionPath, 'test2.txt')).createSync();
    io.Directory(p.join(collectionPath, 'subdir')).createSync();
    io.File(p.join(collectionPath, 'subdir', 'test3.txt')).createSync();

    print('Test: Files seeded in $collectionPath');

    // 3. Trigger Scanner
    final scannerManager = ScannerManager(db);
    final collection = await (db.select(db.collections)..where((t) => t.id.equals(colId))).getSingle();
    
    print('Test: Starting scanner for ${collection.name}');
    await tester.runAsync(() async {
      await scannerManager.startScanner(collection);
    });
    print('Test: scanner.start() finished in test');

    // 4. Wait for database persistence
    print('Test: Waiting for files to reach DB...');
    await tester.runAsync(() async {
      int retries = 0;
      int count = 0;
      while (retries < 40) {
        final files = await (db.select(db.files)..where((t) => t.collectionId.equals(colId))).get();
        count = files.length;
        print('Test: DB file count = $count');
        if (count >= 2) break;
        await Future.delayed(const Duration(milliseconds: 500));
        retries++;
      }
      expect(count, greaterThanOrEqualTo(2), reason: 'Should have found at least 2 files in root');
    });

    // 5. Verify UI Rendering
    print('Test: Pumping RxFilesPage...');
    
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RxFilesPage(),
        ),
      ),
    );

    // We need to set the selected collection for RxFilesPage AFTER pumpWidget (so it's listening)
    RxFilesPage.selectedCollection.add(collection);

    // Allow data to load and UI to settle
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Verify file names are present in the list
    expect(find.text('test1.txt'), findsOneWidget);
    expect(find.text('test2.txt'), findsOneWidget);
    expect(find.text('subdir'), findsOneWidget);
    
    print('Test: Integration test passed!');
  });
}
