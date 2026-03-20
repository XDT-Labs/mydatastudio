import 'dart:isolate';

import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/email/services/scanners/yahoo_scanner_isolate.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';
import 'package:flutter/services.dart';

class YahooScanner extends CollectionScanner {
  final SendPort? dbWriterPort;
  final String dbPath;
  final Collection collection;
  final String appDir;
  YahooScannerIsolate? isolate;
  bool isStopped = false;

  final AppLogger logger = AppLogger(null);

  YahooScanner({
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
    // check if scan has already been run once
    if (!force && collection.lastScanDate != null) return Future(() => 0);

    // TODO: start isolate and perform sync
    logger.i("Yahoo sync started (stub)");

    return 0;
  }

  @override
  void stop() async {
    isStopped = true;
    // isolate?.stop();
  }
}
