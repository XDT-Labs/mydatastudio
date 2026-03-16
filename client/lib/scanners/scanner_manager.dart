import 'dart:async';
import 'dart:isolate';

import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/services/scanners/google_file_scanner.dart';
import 'package:mydatatools/modules/files/services/scanners/local_file_isolate.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';

class ScannerManager {
  final AppLogger logger = AppLogger(null);
  static final ScannerManager _instance = ScannerManager._internal();
  List<Collection> collections = [];
  Map<String, CollectionScanner> scanners = {};

  late AppDatabase database;
  //class reference to keep change listeners running
  StreamSubscription<List<Collection>>? collectionSubs;

  // todo: pass in a dedicated writer thread
  factory ScannerManager(AppDatabase database) {
    _instance.database = database;
    return _instance;
  }

  static ScannerManager getInstance() {
    return _instance;
  }

  ScannerManager._internal() {
    // initialization logic
    //_instance.startScanners();
  }

  void startScanners() async {
    // Delay scanner startup to let the app UI finish initializing and prevent startup lockups
    await Future.delayed(const Duration(seconds: 5));

    //start scanner for all existing collections
    var collections = await database.select(database.collections).get();
    for (var c in collections) {
      await Future.delayed(const Duration(seconds: 5));
      logger.d('${c.id} | ${c.path}');
      _registerSingleScanner(c);
    }

    //listen for new collections and add them at runtime
    Stream<List<Collection>> collectionWatch =
        database.select(database.collections).watch();

    collectionWatch.listen((changes) {
      logger.d('Value from controller: $changes');

      // Check for new collections to add
      for (var c in changes) {
        if (getScanner(c) == null) {
          _registerSingleScanner(c);
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

  void stopScanners() {
    try {
      for (var key in scanners.keys) {
        scanners[key]!.stop();
        scanners.remove(key);
      }
    } catch (error) {
      //print(error);
    }
  }

  void startScanner(Collection c) {
    // TODO, not implemented yet
  }

  CollectionScanner? getScanner(Collection c) {
    return scanners[c.id];
  }

  void _registerSingleScanner(Collection c) async {
    switch (c.scanner) {
      case AppConstants.scannerFileLocal:
        logger.i("Register '${c.scanner}' scanner for ${c.name} | ${c.path}");
        SendPort? writerPort = await DatabaseManager.instance.writerPort;
        CollectionScanner localScanner = LocalFileIsolate(
          null,
          writerPort,
        );
        scanners.putIfAbsent(c.id, () => localScanner);
        break;

      case AppConstants.scannerFileGDrive:
        logger.i("Registering GDrive scanner for ${c.name} (ID: ${c.id})");
        SendPort driveWriterPort = await DatabaseManager.instance.writerPort;
        CollectionScanner cloudScanner = CloudFileIsolate(
          null, // Central logger port not used yet
          driveWriterPort,
        );
        scanners[c.id] = cloudScanner;
        
        logger.i("Starting initial scan for ${c.name}...");
        // Kick off the initial scan immediately
        cloudScanner.start(c, c.path, true, false).then((val) {
          logger.i("Initial scan request completed with return code: $val");
        }).catchError((e) {
          logger.e("Initial scan request failed", error: e);
        });
        break;

      case AppConstants.scannerEmailGmail:
        logger.i("Register '${c.scanner}' scanner for ${c.name} | ${c.path}");
        // Gmail scanner registration handled elsewhere
        break;

      default:
        logger.w("Scanner type '${c.scanner}' not recognized.");
        break;
    }
  }
}
