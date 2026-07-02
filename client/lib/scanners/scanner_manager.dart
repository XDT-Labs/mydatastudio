import 'dart:async';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/files/services/scanners/google_file_scanner.dart';
import 'package:mydatastudio/modules/files/services/scanners/local_file_isolate.dart';
import 'package:mydatastudio/modules/email/services/scanners/gmail_scanner.dart';
import 'package:mydatastudio/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';
import 'package:mydatastudio/modules/email/services/scanners/outlook_scanner.dart';

import 'package:mydatastudio/modules/email/services/scanners/yahoo_scanner.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';

typedef ScannerFactory = Future<CollectionScanner> Function(Collection c);

class ScannerManager {
  final AppLogger logger = AppLogger(null);
  static final ScannerManager _instance = ScannerManager.internal();
  List<Collection> collections = [];
  Map<String, CollectionScanner> scanners = {};
  Map<String, OutlookPstScannerIsolate> pstScanners = {};

  late AppDatabase database;
  //class reference to keep change listeners running
  StreamSubscription<List<Collection>>? collectionSubs;

  @visibleForTesting
  ScannerFactory? scannerFactory;

  // todo: pass in a dedicated writer thread
  factory ScannerManager(AppDatabase database) {
    _instance.database = database;
    return _instance;
  }

  static ScannerManager getInstance() {
    return _instance;
  }

  @visibleForTesting
  ScannerManager.internal() {
    // initialization logic
    //_instance.startScanners();
  }

  Future<void> startScanners() async {
    // Delay scanner startup to let the app UI finish initializing and prevent startup lockups
    await Future.delayed(const Duration(seconds: 5));

    //register scanners for all existing collections (no full scan on startup)
    var collections = await getAllCollections();
    for (var c in collections) {
      if (c.scanner == AppConstants.scannerEmailOutlookPst) {
        continue;
      }
      await Future.delayed(const Duration(seconds: 1));
      logger.i('Registering scanner for ${c.name} | ${c.path}');
      await registerScanner(c);
    }

    //listen for new collections and add them at runtime
    Stream<List<Collection>> collectionWatch = watchCollections();

    collectionWatch.listen((changes) {
      logger.d('Value from controller: $changes');

      // Check for new collections to add
      for (var c in changes) {
        if (c.scanner == AppConstants.scannerEmailOutlookPst) {
          continue;
        }
        if (getScanner(c) == null) {
          registerScanner(c);
        }
      }

      // Check for deleted collections to remove
      final currentIds = changes.map((c) => c.id).toSet();
      final scannerIds = scanners.keys.toList();
      for (final id in scannerIds) {
        if (!currentIds.contains(id)) {
          logger.i("Removing scanner for deleted collection: $id");
          scanners[id]?.stop();
          scanners.remove(id);
        }
      }
    });
  }

  void stopScanner(String collectionId) {
    if (scanners.containsKey(collectionId)) {
      logger.i("Stopping scanner for collection: $collectionId");
      scanners[collectionId]?.stop();
      scanners.remove(collectionId);
    }
    if (pstScanners.containsKey(collectionId)) {
      logger.i("Stopping PST scanner for collection: $collectionId");
      pstScanners[collectionId]?.stop();
      pstScanners.remove(collectionId);
    }
    _registrationFutures.remove(collectionId);
    _pendingScanners.remove(collectionId);
  }

  void stopScanners() {
    try {
      for (var key in scanners.keys.toList()) {
        stopScanner(key);
      }
      for (var key in pstScanners.keys.toList()) {
        stopScanner(key);
      }
      _registrationFutures.clear();
      _pendingScanners.clear();
    } catch (error) {
      logger.e("Error stopping scanners: $error");
    }
  }

  Future<void> startScanner(Collection c) async {
    final scanner = await registerScanner(c);
    await scanner.start(c, null, true, true);
  }

  CollectionScanner? getScanner(Collection c) {
    return scanners[c.id];
  }

  final Map<String, Completer<CollectionScanner>> _pendingScanners = {};
  final Map<String, Future<CollectionScanner>> _registrationFutures = {};

  /// Returns a Future that completes when a scanner is registered for the collection.
  /// If it's already registered, the Future completes immediately.
  Future<CollectionScanner> getScannerAsync(Collection c) {
    if (scanners.containsKey(c.id)) {
      return Future.value(scanners[c.id]!);
    }
    return _pendingScanners
        .putIfAbsent(c.id, () => Completer<CollectionScanner>())
        .future;
  }

  Future<CollectionScanner> registerScanner(Collection c) async {
    print("DEBUG registerScanner: scanners keys = ${scanners.keys.toList()}, futures keys = ${_registrationFutures.keys.toList()}");
    if (scanners.containsKey(c.id)) return scanners[c.id]!;

    // If registration is already in progress, return the existing future
    if (_registrationFutures.containsKey(c.id)) {
      return _registrationFutures[c.id]!;
    }

    final future = _doRegisterScanner(c);
    _registrationFutures[c.id] = future;
    return future;
  }

  Future<CollectionScanner> _doRegisterScanner(Collection c) async {
    if (scannerFactory != null) {
      final scanner = await scannerFactory!(c);
      scanners[c.id] = scanner;
      return scanner;
    }

    try {
      CollectionScanner scanner;
      switch (c.scanner) {
        case AppConstants.scannerFileLocal:
          logger.i("Register '${c.scanner}' scanner for ${c.name} | ${c.path}");
          scanner = LocalFileIsolate(
            null,
            storagePath: DatabaseManager.instance.databaseDirectoryPath!,
            dbName: AppConstants.dbName,
          );
          break;

        case AppConstants.scannerFileGDrive:
          logger.i("Registering GDrive scanner for ${c.name} (ID: ${c.id})");
          scanner = CloudFileIsolate(
            null,
            storagePath: DatabaseManager.instance.databaseDirectoryPath!,
            dbName: AppConstants.dbName,
          );
          break;

        case AppConstants.scannerEmailGmail:
          logger.i("Register '${c.scanner}' scanner for ${c.name} | ${c.path}");
          scanner = GmailScanner(
            dbPath: p.join(
              DatabaseManager.instance.databaseDirectoryPath!,
              'data',
              AppConstants.dbName,
            ),
            collection: c,
            appDir: DatabaseManager.instance.storagePath!,
          );
          break;

        case AppConstants.scannerEmailYahoo:
          logger.i("Register '${c.scanner}' scanner for ${c.name} | ${c.path}");
          scanner = YahooScanner(
            dbPath: p.join(
              DatabaseManager.instance.databaseDirectoryPath!,
              'data',
              AppConstants.dbName,
            ),
            collection: c,
            appDir: DatabaseManager.instance.storagePath!,
          );
          break;

        case AppConstants.scannerEmailOutlook:
          logger.i("Register '${c.scanner}' scanner for ${c.name} | ${c.path}");
          scanner = OutlookScanner(
            dbPath: p.join(
              DatabaseManager.instance.databaseDirectoryPath!,
              'data',
              AppConstants.dbName,
            ),
            collection: c,
            appDir: DatabaseManager.instance.storagePath!,
          );
          break;

        case AppConstants.scannerEmailOutlookPst:
          // Handled as a one-time import via direct isolate call in UI.
          // We silently ignore it here to suppress the "type not recognized" warning on startup.
          throw Exception(
            "Outlook PST scanner is handled via direct isolate call and cannot be registered in ScannerManager.",
          );

        default:
          logger.w("Scanner type '${c.scanner}' not recognized.");
          throw Exception("Scanner type '${c.scanner}' not recognized.");
      }

      scanners[c.id] = scanner;
      _pendingScanners.remove(c.id)?.complete(scanner);
      return scanner;
    } finally {
      _registrationFutures.remove(c.id);
    }
  }

  Future<List<Collection>> getAllCollections() async {
    final rows = await database.select("SELECT * FROM collections");
    return rows.map((r) => Collection.fromDbMap(r)).toList();
  }

  Stream<List<Collection>> watchCollections() {
    return database.stream("SELECT * FROM collections").map((rows) {
      return rows.map((r) => Collection.fromDbMap(r)).toList();
    });
  }
}
