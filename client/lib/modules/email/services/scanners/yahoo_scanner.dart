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

    // If scanning already, don't restart.
    if (isScanning.value) return 0;
    
    isScanning.add(true);
    logger.i("Yahoo sync started for ${collection.name}");

    //start full scan in isolate
    ReceivePort receivePort = ReceivePort();
    receivePort.listen((message) {
      if (message is String && message.isNotEmpty) {
        logger.s(message);
      }
      if (message is Map && message['status'] == 'done') {
        isScanning.add(false);
      }
    });

    //start isolate
    RootIsolateToken? token = RootIsolateToken.instance;
    isolate = YahooScannerIsolate(
      token: token,
      dbWriterPort: dbWriterPort,
      appDir: appDir,
    );
    await isolate!.start(
      collection,
      folderId: path,
      force: force,
      statusPort: receivePort.sendPort,
    );

    return 0;
  }

  @override
  Future<void> moveToTrash(
    Collection collection,
    String folderId,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return;
    
    // Lazy-init isolate if needed
    isolate ??= YahooScannerIsolate(
      token: RootIsolateToken.instance,
      dbWriterPort: dbWriterPort,
      appDir: appDir,
    );
    
    await isolate!.moveToTrash(
      collection,
      folderId: folderId,
      uids: uids,
    );
  }

  @override
  void stop() async {
    isStopped = true;
    isolate?.stop();
    isScanning.add(false);
  }
}
