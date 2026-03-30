import 'dart:isolate';

import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/email/services/scanners/gmail_scanner_isolate.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';
import 'package:flutter/services.dart';

// TODO
//@see https://pub.dev/packages/driven
class GmailScanner extends CollectionScanner {
  final SendPort? dbWriterPort;
  final String dbPath;
  final Collection collection;
  final String appDir;
  GmailScannerIsolate? isolate;
  bool isStopped = false;

  final AppLogger logger = AppLogger(null);

  GmailScanner({
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
    logger.i("Gmail sync started for ${collection.name}");

    //start full scan in isolate
    ReceivePort receivePort = ReceivePort();
    receivePort.listen((message) {
      //listen for logger status messages
      if (message is String && message.isNotEmpty) {
        logger.s(message);
      }
      if (message is Map && message['status'] == 'done') {
        isScanning.add(false);
      }
    });

    // If the path looks like a local file path (e.g., from the Files module), 
    // we don't want to pass it to Gmail as a label ID. 
    String? labelId;
    if (path != null && !path.startsWith('/') && !path.contains(appDir)) {
      labelId = path;
    }

    //start isolate
    RootIsolateToken? token = RootIsolateToken.instance;
    isolate = GmailScannerIsolate(
      token: token,
      dbWriterPort: dbWriterPort,
      appDir: appDir,
    );
    await isolate!.start(
      collection,
      folderId: labelId,
      force: force,
      statusPort: receivePort.sendPort,
    );

    return 0;
  }

  @override
  void stop() async {
    isStopped = true;
    isolate?.stop();
    isScanning.add(false);
  }
}
