import 'dart:isolate';
import 'package:path/path.dart' as p;

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/scanners/yahoo_scanner_isolate.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';
import 'package:flutter/services.dart';

/// [YahooScanner] is a collection scanner responsible for indexing emails
/// from a Yahoo account via IMAP. It manages the lifecycle of the
/// [YahooScannerIsolate] and bridges communication between the UI and worker.
///
/// Synchronization Rules:
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
class YahooScanner extends CollectionScanner {
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
  });

  /// Starts the Yahoo scanning process.
  ///
  /// [collection] The Yahoo collection to scan.
  /// [path] Mode selector:
  ///   - If NULL: **Full Sync**. Exhaustively traverses all IMAP folders.
  ///   - If NOT NULL: **Targeted Scan**. Focuses ONLY on the specified folder ID
  ///     (e.g., 'INBOX', 'Sent') for immediate results during navigation.
  /// [recursive] Whether to scan subfolders.
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
      appDir: appDir,
      dbDir: p.dirname(p.dirname(dbPath)),
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
      appDir: appDir,
      dbDir: p.dirname(p.dirname(dbPath)),
    );

    await isolate!.moveToTrash(collection, folderId: folderId, uids: uids);
  }

  @override
  void stop() async {
    isStopped = true;
    isolate?.stop();
    isScanning.add(false);
  }
}
