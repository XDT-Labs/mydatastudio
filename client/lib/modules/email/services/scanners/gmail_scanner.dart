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
    // check if scan has already been run once
    if (!force && collection.lastScanDate != null) return Future(() => 0);
    // TODO: add a date range check to rerun scan

    //start full scan in isolate
    ReceivePort receivePort = ReceivePort();
    receivePort.listen((message) {
      //listen for logger status messages
      if (message is String && message.isNotEmpty) {
        logger.s(message);
      }
    });

    //start isolate
    RootIsolateToken? token = RootIsolateToken.instance;
    isolate = GmailScannerIsolate(
      token: token,
      dbWriterPort: dbWriterPort,
      appDir: appDir,
    );
    await isolate!.start(
      collection,
      folderId: path,
      force: force,
    );

    return 0;
  }

  @override
  void stop() async {
    isStopped = true;
    isolate?.stop();
  }
}
