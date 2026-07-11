import 'dart:isolate';
import 'package:path/path.dart' as p;

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/scanners/gmail_scanner_isolate.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';
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
  GmailScannerIsolate? _fullScanIsolateManager;
  int _activeScanningCount = 0;
  bool isStopped = false;

  final AppLogger logger = AppLogger(null);

  GmailScanner({
    required this.dbPath,
    required this.collection,
    required this.appDir,
  });

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
    // If scanning already, don't restart.
    if (!force) {
      logger.i("Registration-only mode: skipping scan for ${collection.name}");
      return 0;
    }

    // If the path looks like a local file path (e.g., from the Files module),
    // we don't want to pass it to Gmail as a label ID.
    String? labelId;
    if (path != null && !path.startsWith('/') && !path.contains(appDir)) {
      labelId = path;
    }

    // Only skip if the scanner is already busy AND it's a full scan
    if (isScanning.value && labelId == null) {
      return 0;
    }

    if (labelId == null && force) {
      // Force recursive full scan: stop existing background scan first
      _fullScanIsolateManager?.stop();
      _fullScanIsolateManager = null;
    }

    _activeScanningCount++;
    isScanning.add(true);
    bool hasDecremented = false;
    logger.i("Gmail sync started for ${collection.name} (label: $labelId)");

    //start scan in isolate
    ReceivePort receivePort = ReceivePort();
    receivePort.listen((message) {
      //listen for logger status messages
      if (message is String && message.isNotEmpty) {
        logger.s(message);
      }
      if (message is Map && message['status'] == 'done') {
        if (!hasDecremented) {
          hasDecremented = true;
          _activeScanningCount--;
          if (_activeScanningCount <= 0) {
            _activeScanningCount = 0;
            isScanning.add(false);
          }
        }
        receivePort.close();
      }
    });

    //start isolate
    RootIsolateToken? token = RootIsolateToken.instance;
    final scannerIsolate = GmailScannerIsolate(
      token: token,
      appDir: appDir,
      dbDir: p.dirname(p.dirname(dbPath)),
    );
    if (labelId == null) {
      _fullScanIsolateManager = scannerIsolate;
    }

    await scannerIsolate.start(
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
    _fullScanIsolateManager?.stop();
    _fullScanIsolateManager = null;
    _activeScanningCount = 0;
    isScanning.add(false);
  }
}
