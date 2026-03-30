import 'dart:isolate';

import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/email/services/scanners/outlook_scanner_isolate.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';
import 'package:flutter/services.dart';

class OutlookScanner extends CollectionScanner {
  final SendPort? dbWriterPort;
  final String dbPath;
  final Collection collection;
  final String appDir;
  OutlookScannerIsolate? isolate;
  bool isStopped = false;

  final AppLogger logger = AppLogger(null);

  OutlookScanner({
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
    // We no longer skip scanning if lastScanDate is not null. 
    // The underlying isolate will handle incremental sync logic based on the date.

    // If scanning already, don't restart.
    if (isScanning.value) return 0;
    
    isScanning.add(true);
    logger.i("Outlook sync started for ${collection.name}");

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
    isolate = OutlookScannerIsolate(
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
    isolate ??= OutlookScannerIsolate(
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
