import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';
import 'dart:isolate';
import 'package:flutter/services.dart';

class OutlookPstScanner extends CollectionScanner {
  final SendPort? dbWriterPort;
  final String dbPath;
  final Collection collection;
  final String appDir;
  OutlookPstScannerIsolate? isolate;

  final AppLogger logger = AppLogger(null);

  OutlookPstScanner({
    required this.dbPath,
    required this.collection,
    required this.appDir,
    this.dbWriterPort,
  });

  @override
  Future<int> start(
    Collection collection,
    String? path,
    bool recursive,
    bool force,
  ) async {
    // Check if scan is already complete
    if (!force && collection.lastScanDate != null) return 0;

    // The 'path' in the collection is the actual .pst file path.
    // We launch the isolate which will call the Python helper.
    isolate = OutlookPstScannerIsolate(
      token: RootIsolateToken.instance,
      dbWriterPort: dbWriterPort,
      appDir: appDir,
    );

    await isolate!.start(collection, force: force);

    return 0;
  }

  @override
  void stop() {
    isolate?.stop();
  }
}
