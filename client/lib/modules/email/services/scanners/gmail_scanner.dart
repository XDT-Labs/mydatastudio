import 'dart:isolate';

import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/email/services/scanners/gmail_scanner_isolate.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';
import 'package:flutter/services.dart';

/// [GmailScanner] is a collection scanner responsible for indexing emails
/// from a Gmail account. It manages the lifecycle of the [GmailScannerIsolate]
/// and bridges communication between the UI and the background worker.
///
/// Synchronization Rules:
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
class GmailScanner extends CollectionScanner {
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
  });

  /// Starts the Gmail scanning process.
  ///
  /// [collection] The Google/Gmail collection to scan.
  /// [path] Optional label ID (e.g., 'INBOX') to restrict the scan.
  /// [recursive] Not currently used for Gmail (labels are flat).
  /// [force] If false, returns 0 immediately (Rule 2). If true, triggers sync.
  /// Starts the Gmail scanning process.
  ///
  /// [collection] The Gmail collection to scan.
  /// [path] Mode selector:
  ///   - If NULL: **Full Sync**. Exhaustively traverses all labels/folders.
  ///   - If NOT NULL: **Targeted Scan**. Focuses ONLY on the specified folder ID
  ///     (e.g., 'INBOX', 'Sent') for immediate results during navigation.
  /// [recursive] Whether to scan sub-labels.
  /// [force] If false, returns 0 immediately (Rule 2). If true, triggers sync.
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
    if (!force) {
      logger.i("Registration-only mode: skipping scan for ${collection.name}");
      return 0;
    }
    
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
