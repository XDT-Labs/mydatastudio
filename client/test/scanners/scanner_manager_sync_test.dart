import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:rxdart/rxdart.dart';

class MockAppDatabase extends Mock implements AppDatabase {}

class MockScanner extends Mock implements CollectionScanner {
  @override
  final isScanning = BehaviorSubject<bool>.seeded(false);

  @override
  void stop() {}
}

class TestScannerManager extends ScannerManager {
  TestScannerManager(AppDatabase database) : super.internal() {
    this.database = database;
  }

  List<Collection> mockCollections = [];

  @override
  Future<List<Collection>> getAllCollections() async => mockCollections;

  @override
  Stream<List<Collection>> watchCollections() => Stream.value(mockCollections);
}

void main() {
  late MockAppDatabase mockDb;
  late TestScannerManager scannerManager;
  late MockScanner mockScanner;

  setUpAll(() {
    registerFallbackValue(
      Collection(
        id: 'test-id',
        name: 'Test',
        path: '/test',
        type: 'local',
        scanner: 'local',
        scanStatus: 'idle',
        needsReAuth: false,
      ),
    );
  });

  setUp(() {
    mockDb = MockAppDatabase();
    scannerManager = TestScannerManager(mockDb);
    mockScanner = MockScanner();

    // Inject mock scanner factory
    scannerManager.scannerFactory = (c) async => mockScanner;
  });

  group('ScannerManager Synchronization Rules', () {
    test(
      'startScanners (Startup) MUST ONLY register scanners and NOT call start()',
      () async {
        final collection = Collection(
          id: 'test-id',
          name: 'Test Collection',
          path: '/test/path',
          type: 'local',
          scanner: 'local',
          scanStatus: 'idle',
          needsReAuth: false,
        );
        scannerManager.mockCollections = [collection];

        when(
          () => mockScanner.start(any(), any(), any(), any()),
        ).thenAnswer((_) async => 0);

        await scannerManager.startScanners();

        // Verify scanner was registered (added to the map)
        expect(scannerManager.getScanner(collection), isNotNull);

        // Verify start() was NOT called
        verifyNever(() => mockScanner.start(any(), any(), any(), any()));
      },
    );

    test(
      'startScanner (Manual/New) MUST call start() with force: true',
      () async {
        final collection = Collection(
          id: 'test-id',
          name: 'Test Collection',
          path: '/test/path',
          type: 'local',
          scanner: 'local',
          scanStatus: 'idle',
          needsReAuth: false,
        );

        when(
          () => mockScanner.start(any(), any(), any(), any()),
        ).thenAnswer((_) async => 0);

        await scannerManager.startScanner(collection);

        // Verify scanner was registered
        expect(scannerManager.getScanner(collection), isNotNull);

        // Verify start was called with force: true and recursive: true
        verify(
          () => mockScanner.start(
            any(),
            null,
            true, // recursive
            true, // force (full scan)
          ),
        ).called(1);
      },
    );
  });
}
