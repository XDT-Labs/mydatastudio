import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/services/scanners/local_file_isolate.dart';
import 'package:mydatatools/modules/files/services/scanners/google_file_scanner.dart';
import 'package:mydatatools/modules/email/services/scanners/gmail_scanner_isolate.dart';
import 'package:mydatatools/modules/email/services/scanners/outlook_scanner_isolate.dart';
import 'package:mydatatools/modules/email/services/scanners/yahoo_scanner_isolate.dart';

class TestLocalFileIsolate extends LocalFileIsolate {
  TestLocalFileIsolate(SendPort? loggerPort)
      : super(loggerPort, storagePath: '/tmp', dbName: 'test.db');

  Map<String, dynamic>? lastSpawnArgs;

  @override
  Future<Isolate?> spawnIsolate(void Function(Map<String, dynamic>) entryPoint, Map<String, dynamic> args) async {
    lastSpawnArgs = args;
    final SendPort port = args['port'] as SendPort;
    port.send({'type': 'scan_complete'});
    port.send(null); // Signal exit
    return null;
  }
}

class TestCloudFileIsolate extends CloudFileIsolate {
  TestCloudFileIsolate(SendPort? loggerPort)
      : super(loggerPort, storagePath: '/tmp', dbName: 'test.db');

  Map<String, dynamic>? lastSpawnArgs;

  @override
  Future<Isolate?> spawnIsolate(
    void Function(Map<String, dynamic>) entryPoint,
    Map<String, dynamic> args, {
    String? debugName,
  }) async {
    lastSpawnArgs = args;
    final SendPort port = args['port'] as SendPort;
    port.send({'type': 'scan_complete'});
    port.send(null); // Signal exit
    return null;
  }
}

class TestGmailScannerIsolate extends GmailScannerIsolate {
  TestGmailScannerIsolate({required String appDir})
      : super(appDir: appDir);

  Map<String, dynamic>? lastSpawnArgs;

  @override
  Future<Isolate?> spawnIsolate(void Function(Map<String, dynamic>) entryPoint, Map<String, dynamic> args) async {
    lastSpawnArgs = args;
    final SendPort port = args['port'] as SendPort;
    port.send({'status': 'done'});
    return null;
  }
}

class TestOutlookScannerIsolate extends OutlookScannerIsolate {
  TestOutlookScannerIsolate({required String appDir})
      : super(appDir: appDir);

  Map<String, dynamic>? lastSpawnArgs;

  @override
  Future<Isolate?> spawnIsolate(void Function(Map<String, dynamic>) entryPoint, Map<String, dynamic> args) async {
    lastSpawnArgs = args;
    final SendPort port = args['port'] as SendPort;
    port.send({'status': 'done'});
    return null;
  }
}

class TestYahooScannerIsolate extends YahooScannerIsolate {
  TestYahooScannerIsolate({required String appDir})
      : super(appDir: appDir);

  Map<String, dynamic>? lastSpawnArgs;

  @override
  Future<Isolate?> spawnIsolate(void Function(Map<String, dynamic>) entryPoint, Map<String, dynamic> args) async {
    lastSpawnArgs = args;
    final SendPort port = args['port'] as SendPort;
    port.send({'status': 'done'});
    return null;
  }
}

class MockIsolate extends Mock {}

class MockSendPort extends Mock implements SendPort {}

void main() {
  late Collection collection;

  setUp(() {
    collection = Collection(
      id: 'test-id',
      name: 'Test',
      path: '/test',
      type: 'local',
      scanner: 'local',
      scanStatus: 'idle',
      needsReAuth: false,
    );
  });

  group('Individual Scanner Isolate Propagation', () {
    test('LocalFileIsolate propagates force: true for manual sync', () async {
      final scanner = TestLocalFileIsolate(null);
      await scanner.start(collection, null, true, true); // force: true

      expect(scanner.lastSpawnArgs?['force'], isTrue);
      expect(scanner.lastSpawnArgs?['recursive'], isTrue);
    });

    test('LocalFileIsolate propagates force: false for startup registration', () async {
      final scanner = TestLocalFileIsolate(null);
      await scanner.start(collection, null, true, false); // force: false

      expect(scanner.lastSpawnArgs, isNull, reason: 'Rule 2: Should not spawn isolate if force=false');
    });

    test('CloudFileIsolate propagates force: false for startup registration', () async {
      final scanner = TestCloudFileIsolate(null);
      await scanner.start(collection, null, true, false);

      expect(scanner.lastSpawnArgs, isNull, reason: 'Rule 2');
    });

    test('GmailScannerIsolate propagates force: false for startup registration', () async {
      final scanner = TestGmailScannerIsolate(appDir: 'app');
      await scanner.start(collection, force: false);

      expect(scanner.lastSpawnArgs, isNull, reason: 'Rule 2');
    });

    test('OutlookScannerIsolate propagates force: false for startup registration', () async {
      final scanner = TestOutlookScannerIsolate(appDir: 'app');
      await scanner.start(collection, force: false);

      expect(scanner.lastSpawnArgs, isNull, reason: 'Rule 2');
    });

    test('YahooScannerIsolate propagates force: false for startup registration', () async {
      final scanner = TestYahooScannerIsolate(appDir: 'app');
      await scanner.start(collection, force: false);

      expect(scanner.lastSpawnArgs, isNull, reason: 'Rule 2');
    });

    test('CloudFileIsolate propagates force: true for manual sync', () async {
      final scanner = TestCloudFileIsolate(null);
      await scanner.start(collection, null, true, true);

      expect(scanner.lastSpawnArgs?['force'], isTrue);
    });

    test('GmailScannerIsolate propagates force: true for manual sync', () async {
      final scanner = TestGmailScannerIsolate(appDir: 'app');
      await scanner.start(collection, force: true);

      expect(scanner.lastSpawnArgs?['force'], isTrue);
    });

    test('OutlookScannerIsolate propagates force: true for manual sync', () async {
      final scanner = TestOutlookScannerIsolate(appDir: 'app');
      await scanner.start(collection, force: true);

      expect(scanner.lastSpawnArgs?['force'], isTrue);
    });

    test('YahooScannerIsolate propagates force: true for manual sync', () async {
      final scanner = TestYahooScannerIsolate(appDir: 'app');
      await scanner.start(collection, force: true);

      expect(scanner.lastSpawnArgs?['force'], isTrue);
    });
  });
}
