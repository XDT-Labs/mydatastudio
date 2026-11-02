import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';
import 'package:mydatastudio/scanners/scan_isolate_support.dart';
import 'package:mydatastudio/services/credential_codec.dart';
import 'package:mydatastudio/services/scan_write_relay.dart';
import 'package:mydatastudio/services/vault_manager.dart';
import 'package:path/path.dart' as p;

/// Scanner lifecycle manager for cloud file sources (Google Drive, and any
/// future provider that implements [CloudFileApi]).
///
/// Extends [CollectionScanner] — the same base used by [LocalFileIsolate] —
/// but walks a remote drive through a [CloudFileApi] built *inside* the spawned
/// isolate by [apiFactory] from raw token strings (live clients can't cross
/// isolate boundaries).
///
/// Synchronization Rules:
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
///
/// Relays `batchFile`, `folder`, `cleanupDeletedFiles`, and `collectionStatus`
/// writes to the main isolate via [writeViaMain] instead of writing through
/// its own connection — see `scan_write_relay.dart`'s
/// `handleScanWriteMessage` for where they're actually executed.
class CloudFileScanner extends CollectionScanner {
  final SendPort? loggerIsolatePort;
  final String? storagePath;

  /// The user's storage root (`DatabaseManager.storagePath`), where downloaded
  /// local copies belong. Distinct from [storagePath] above, which is the
  /// *database* directory — the two diverge when the chosen storage location
  /// can't run SQLite in WAL mode and the db is redirected to Application
  /// Support. Downloads have to follow the storage root the user picked, or
  /// enabling "download local copy" on a large Drive silently fills the boot
  /// volume instead of the drive they chose.
  final String? appDir;
  final String? dbName;

  /// Builds the provider adapter inside the isolate. Top-level/static only.
  final CloudFileApiFactory apiFactory;

  /// Every isolate this scanner has spawned, recursive and shallow alike, so
  /// [stop] can reach a shallow (single-folder) scan spawned alongside a
  /// recursive one.
  final Set<Isolate> _liveIsolates = {};
  AppLogger? _logger;
  int _activeScanningCount = 0;

  CloudFileScanner(
    this.loggerIsolatePort, {
    this.storagePath,
    this.appDir,
    this.dbName,
    required this.apiFactory,
  }) : super() {
    _logger = AppLogger(loggerIsolatePort);
  }

  /// Starts the cloud file scanning process.
  ///
  /// [collection] The cloud collection to scan.
  /// [path] Mode selector:
  ///   - If NULL: **Full Sync**. Exhaustively traverses the entire cloud collection root.
  ///   - If NOT NULL: **Targeted Scan**. Focuses ONLY on the specified folder ID
  ///     for immediate results during navigation.
  /// [recursive] Whether to scan subfolders.
  /// [force] If false, returns 0 immediately (Rule 2). If true, triggers sync.
  @override
  Future<int> start(
    Collection collection,
    String? path,
    bool recursive,
    bool force,
  ) async {
    if (!force) {
      _logger?.i(
        "Registration-only mode: skipping scan for ${collection.name}",
      );
      return 0;
    }

    if (force && recursive) {
      stop();
    }

    _activeScanningCount++;
    isScanning.add(true);
    bool hasDecremented = false;

    final String debugName = 'CloudFileIsolate_${collection.id}';

    final ReceivePort p = ReceivePort(debugName);
    final token = RootIsolateToken.instance!;

    final String actualPath =
        (path != null && path.isNotEmpty) ? path : collection.path;

    // Only pass isolate-safe primitives across the boundary
    final Map<String, dynamic> args = {
      'token': token,
      'port': p.sendPort,
      'storagePath': storagePath,
      'appDir': appDir,
      'dbName': dbName,
      'loggerPort': p.sendPort, // Send logs back through our own ReceivePort
      'collectionId': collection.id,
      'collectionName': collection.name,
      'collectionPath': collection.path,
      'lastScanDate': collection.lastScanDate?.toIso8601String(),
      'downloadLocalCopy': collection.downloadLocalCopy,
      'changeCursor': collection.changeCursor,
      'keepDeletedFiles': collection.keepDeletedFiles,
      // The root folder ID to start scanning from (e.g. 'root' or a specific folder ID)
      'rootFolderId': actualPath,
      'isFullScan': actualPath == collection.path,
      'recursive': recursive,
      'force': force,
      // Raw token strings — the worker re-creates the API client inside the isolate
      'providerKey': collection.scanner,
      'accessToken': collection.accessToken,
      'refreshToken': collection.refreshToken,
      'accessTokenExpiry': collection.expiration?.toIso8601String(),
      'apiFactory': apiFactory,
      // DEK so the worker can decrypt/encrypt collection tokens and read the
      // provider client_secret during token refresh (AUDIT M2 phase 4).
      'vaultDek': VaultManager.instance.dek,
    };

    final spawned = await spawnIsolate(
      CloudFileScannerWorker.entry,
      args,
      debugName: debugName,
    );
    if (spawned != null) {
      _liveIsolates.add(spawned);
    }
    spawned?.addOnExitListener(p.sendPort);

    // Listen for heartbeats, logs, and the exit signal
    await for (final message in p) {
      if (message == null) {
        // Isolate exited (addOnExitListener sends null)
        break;
      }

      if (message is Map) {
        final type = message['type'];
        final msg = message['message'];

        if (type == 'log') {
          // Re-log in main isolate
          final level = message['level'] as String;
          switch (level) {
            case 'info':
              _logger?.i('[$debugName] $msg');
              break;
            case 'error':
              _logger?.e(
                '[$debugName] $msg',
                error: message['error'],
                stackTrace: message['stackTrace'],
              );
              break;
            case 'warning':
              _logger?.w('[$debugName] $msg');
              break;
            case 'debug':
              _logger?.d('[$debugName] $msg');
              break;
            case 'status':
              _logger?.s('[$debugName] $msg');
              break;
            default:
              _logger?.i('[$debugName] $msg');
          }
        } else if (type == 'status') {
          _logger?.s(msg);
        } else if (type == 'dbWrite') {
          // Awaited before the loop pulls the next message — see
          // local_file_isolate.dart for why this ordering matters.
          final replyTo = message['replyTo'] as SendPort;
          try {
            final result = await handleScanWriteMessage(message);
            replyTo.send({'ok': true, 'result': result});
          } catch (e) {
            replyTo.send({'ok': false, 'error': e.toString()});
          }
        } else if (type == 'scan_complete') {
          // The initial scan is done, but the isolate might stay alive for downloads.
          // We let start() return so ScannerManager is unblocked.
          if (!hasDecremented) {
            hasDecremented = true;
            _activeScanningCount--;
            if (_activeScanningCount <= 0) {
              _activeScanningCount = 0;
              isScanning.add(false);
            }
          }
        }
      }
    }

    if (!hasDecremented) {
      hasDecremented = true;
      _activeScanningCount--;
      if (_activeScanningCount <= 0) {
        _activeScanningCount = 0;
        isScanning.add(false);
      }
    }
    p.close();
    return 0;
  }

  @override
  void stop() {
    for (final isolate in _liveIsolates.toList()) {
      isolate.kill(priority: Isolate.beforeNextEvent);
    }
    _liveIsolates.clear();
    _logger?.i('CloudFileIsolate stopped');
  }

  /// Overridable for testing to avoid real isolate spawning
  Future<Isolate?> spawnIsolate(
    void Function(Map<String, dynamic>) entryPoint,
    Map<String, dynamic> args, {
    String? debugName,
  }) async {
    return await Isolate.spawn<Map<String, dynamic>>(
      entryPoint,
      args,
      debugName: debugName,
    );
  }
}

// ---------------------------------------------------------------------------
// Isolate worker — runs entirely inside the spawned isolate
// ---------------------------------------------------------------------------

/// All execution inside the cloud scan isolate. Builds the [CloudFileApi] from
/// raw token strings, then runs the provider-independent scan algorithm.
class CloudFileScannerWorker {
  final AppDatabase appDb;
  final SendPort? loggerPort;
  final SendPort port;
  late final AppLogger logger;

  /// Read seams (default to [appDb]); overridable so the scan loop is testable
  /// without a database.
  final Future<bool> Function(String collectionId) _collectionExists;
  final Future<List<File>> Function(String collectionId) _filesToDownload;

  /// Folder rows already stored for a collection: provider folder id -> parent
  /// provider folder id ('' = collection root). Defines which change-feed
  /// items are inside the collection.
  final Future<Map<String, String>> Function(String collectionId) _knownFolders;

  // Caches for path reconstruction
  final Map<String, String> _folderNames = {};
  final Map<String, String> _folderParents = {};

  /// Batches this scan failed to write. Non-zero means the scan is partial and
  /// the delete-sweep must be skipped: files that never reached the database
  /// still carry an old last_scanned_date, so sweeping would mark records
  /// deleted that are still present in the cloud drive.
  int _failedBatches = 0;

  // Download management
  final List<File> _downloadQueue = [];
  static const int _maxConcurrentDownloads = 3;
  static const int _batchSize = 100;
  bool _isScanning = false;

  CloudFileScannerWorker(
    this.appDb,
    this.loggerPort,
    this.port, {
    Future<bool> Function(String collectionId)? collectionExists,
    Future<List<File>> Function(String collectionId)? filesToDownload,
    Future<Map<String, String>> Function(String collectionId)? knownFolders,
  }) : _knownFolders =
           knownFolders ??
           ((id) async => {
             for (final r in await appDb.select(
               'SELECT path, parent FROM folders WHERE collection_id = ?',
               [id],
             ))
               r['path'] as String: r['parent'] as String,
           }),
       _collectionExists =
           collectionExists ??
           ((id) async =>
               await CollectionRepository(appDb).collectionById(id) != null),
       _filesToDownload =
           filesToDownload ??
           ((id) => FileDesktopRepository(appDb).getFilesToDownload(id)) {
    logger = AppLogger(loggerPort);
  }

  // Top-level isolate entry — must be a static or top-level function.
  static Future<void> entry(Map<String, dynamic> args) async {
    final SendPort? loggerPort = args['loggerPort'] as SendPort?;
    try {
      // Set log level inside the isolate
      Logger.level = Level.debug;

      final token = args['token'] as RootIsolateToken;
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);

      // DEK-backed vault for in-isolate credential access (AUDIT M2 phase 4).
      CredentialCodec.installIsolateVault(args['vaultDek'] as Uint8List?);

      final appDb = await AppDatabase.create(
        null,
        args['storagePath'] as String,
        args['dbName'] as String,
      );

      final worker = CloudFileScannerWorker(
        appDb,
        loggerPort,
        args['port'] as SendPort,
      );

      await worker.scan(args, args['apiFactory'] as CloudFileApiFactory);
    } catch (e, stack) {
      // If we can't even start the worker, relay the failure to the parent so it
      // reaches the log file. Only when there is no port to relay over does this
      // fall back to print — an AppLogger here would be console-only too, since
      // the file sink needs state the isolate doesn't have.
      if (loggerPort != null) {
        loggerPort.send({
          'type': 'log',
          'level': 'error',
          'message': 'CRITICAL: CloudFileIsolate failed to start: $e',
          'stackTrace': stack.toString(),
        });
      } else {
        print('CRITICAL: CloudFileIsolate failed to start: $e\n$stack');
      }
      Isolate.exit(args['port'] as SendPort, 1);
    }
    Isolate.exit(args['port'] as SendPort, 0);
  }

  /// Runs one scan (and the optional download pass). Returns normally in every
  /// case — aborts (no tokens, auth failure) included — so it can be driven
  /// from a test; [entry] is what ends the isolate.
  Future<void> scan(
    Map<String, dynamic> args,
    CloudFileApiFactory apiFactory,
  ) async {
    final collectionId = args['collectionId'] as String;
    final collectionName = args['collectionName'] as String;
    final collectionPath = args['collectionPath'] as String? ?? 'root';
    final rootFolderId = args['rootFolderId'] as String? ?? 'root';
    final changeCursor = args['changeCursor'] as String?;
    final keepDeleted = args['keepDeletedFiles'] as bool? ?? false;
    // Storage root for downloaded copies. `storagePath` in args is the database
    // directory and is only used to open the db — see [CloudFileScanner.appDir].
    final appDir = args['appDir'] as String? ?? args['storagePath'] as String?;
    final downloadLocalCopy = args['downloadLocalCopy'] as bool? ?? false;
    final isFullScan = args['isFullScan'] as bool? ?? false;
    final recursive = args['recursive'] as bool? ?? true;
    final force = args['force'] as bool? ?? false;
    final accessToken = args['accessToken'] as String?;
    final refreshToken = args['refreshToken'] as String?;
    final expiryStr = args['accessTokenExpiry'] as String?;
    final expiry =
        expiryStr != null ? DateTime.tryParse(expiryStr)?.toUtc() : null;

    logger.s('CloudFileIsolate: isolate started for "$collectionName"');

    if (accessToken == null || refreshToken == null) {
      logger.e(
        'CloudFileIsolate: no tokens for collection "$collectionName" — aborting scan',
      );
      return;
    }

    final CloudFileApi api;
    try {
      api = await apiFactory(
        CloudFileApiCredentials(
          accessToken: accessToken,
          refreshToken: refreshToken,
          expiry: expiry,
          db: appDb,
        ),
      );
    } on CloudAuthException catch (e) {
      logger.e(
        'CloudFileIsolate: token refresh failed for "$collectionName": $e',
      );
      if (e.needsReAuth) {
        // Flag it so the app's existing needsReAuth prompt
        // (auth_dialog_manager.dart) tells the user to reconnect, instead of
        // this scan failing silently forever.
        try {
          await writeViaMain(port, 'needsReAuth', {
            'collectionId': collectionId,
          });
        } catch (updateError) {
          logger.w(
            'CloudFileIsolate: failed to flag needsReAuth: $updateError',
          );
        }
      }
      return;
    } catch (e) {
      logger.e(
        'CloudFileIsolate: could not create API client for "$collectionName": $e',
      );
      return;
    }

    final scanStartTime = DateTime.now();
    _isScanning = true;

    try {
      int count = 0;
      bool skipCleanup = false;
      // Position to store once this run has fully applied (see below).
      String? cursorToStore;

      // Incremental = the collection has a change cursor (not lastScanDate,
      // which only says a scan once finished). A forced sync or a targeted
      // folder scan always lists.
      var incremental = isFullScan && !force && changeCursor != null;
      if (incremental) {
        logger.i(
          'CloudFileIsolate: Performing INCREMENTAL sync for "$collectionName" (change cursor)',
        );
        try {
          final result = await _incrementalScan(
            api: api,
            collectionId: collectionId,
            collectionPath: collectionPath,
            cursor: changeCursor,
            keepDeleted: keepDeleted,
            scanStartTime: scanStartTime,
          );
          count = result.count;
          cursorToStore = result.newCursor;
          // The change feed reports deletes, so no sweep is needed.
          skipCleanup = true;
        } on CloudCursorExpiredException catch (e) {
          logger.w(
            'CloudFileIsolate: change cursor rejected for "$collectionName" ($e) — '
            'falling back to a full re-list',
          );
          incremental = false;
          await _writeCursor(collectionId, null);
        }
      }

      if (!incremental) {
        // Take the feed position BEFORE walking, so changes made while the
        // walk runs are replayed by the next incremental sync.
        if (isFullScan) {
          try {
            cursorToStore = await _retryNetworkOp(() => api.startCursor());
          } catch (e) {
            logger.w(
              'CloudFileIsolate: could not get a change cursor ($e) — '
              'next sync will be a full walk again',
            );
          }
        }
        logger.i(
          'CloudFileIsolate: Starting RECURSIVE scan of "$collectionName" from folder "$rootFolderId" (force=$force)',
        );
        count = await _scanFolder(
          api: api,
          collectionId: collectionId,
          collectionPath: collectionPath,
          parentId: rootFolderId,
          recursive: recursive,
          scanStartTime: scanStartTime,
        );
      }

      logger.i(
        'CloudFileIsolate: scan complete — $count items for "$collectionName"',
      );

      if (_failedBatches > 0) {
        logger.w(
          'CloudFileIsolate: $_failedBatches batch(es) failed to save — '
          'skipping the deleted-file sweep so present files are not marked '
          'deleted. The next scan will reconcile.',
        );
      } else if (!skipCleanup) {
        // Mark anything not seen this scan as deleted (full walks / forced refreshes)
        try {
          await writeViaMain(port, 'cleanupDeletedFiles', {
            'collectionId': collectionId,
            'path': rootFolderId == collectionPath ? '' : rootFolderId,
            'scanStartTime': scanStartTime,
            'recursive': recursive,
            'isCloud': true,
            'isFullScan': isFullScan,
            'keepDeleted': keepDeleted,
          });
        } catch (e) {
          // A transient relay failure here shouldn't skip the collection
          // status update below or the download queue after it.
          // A missed sweep means deletes would never be noticed once the
          // cursor moves past them, so don't advance it.
          _failedBatches++;
          logger.e('CloudFileIsolate: cleanup-deleted-files write failed: $e');
        }
      }

      // Only a fully applied run may advance the cursor; otherwise the next
      // run replays from the old position (all writes are idempotent upserts).
      if (_failedBatches == 0 && cursorToStore != null) {
        await _writeCursor(collectionId, cursorToStore);
      }

      // Update lastScanDate in the DB. The read stays on this isolate's own
      // connection; only the write goes back to main.
      if (await _collectionExists(collectionId)) {
        try {
          await writeViaMain(port, 'collectionStatus', {
            'collectionId': collectionId,
            'scanStatus': 'ready',
            'lastScanDate': scanStartTime,
          });
        } catch (e) {
          logger.e('CloudFileIsolate: failed to update collection status: $e');
        }
      }

      _isScanning = false;
      port.send({'type': 'scan_complete'});

      if (downloadLocalCopy && appDir != null) {
        // Query DB for files with null localPath
        logger.i('CloudFileIsolate: querying DB for files needing download...');
        final allFilesNeedingDownload = await _filesToDownload(collectionId);
        _downloadQueue.clear();

        // Skip items the provider can't hand over as plain bytes (e.g. Google
        // Docs/Sheets).
        for (final file in allFilesNeedingDownload) {
          if (api.isDownloadableMimeType(file.contentType)) {
            _downloadQueue.add(file);
          }
        }

        logger.i(
          'CloudFileIsolate: processing download queue (${_downloadQueue.length} items)',
        );
        await _processQueue(api, appDir, collectionName, collectionPath);
      }
    } catch (e, stack) {
      logger.e(
        'CloudFileIsolate: scan error for "$collectionName": $e\n$stack',
      );
    }
  }

  /// Sends [batch] to the main isolate's writer and clears it.
  Future<void> _flushBatch(List<File> batch) async {
    if (batch.isEmpty) return;
    logger.d(
      'CloudFileIsolate: Sending batch of ${batch.length} files to DB writer',
    );
    try {
      await writeViaMain(port, 'batchFile', List<File>.from(batch));
    } catch (e) {
      _failedBatches++;
      logger.e(
        'CloudFileIsolate: batch of ${batch.length} files was not saved: $e',
      );
    }
    batch.clear();
  }

  Future<void> _writeFolder(Folder folder) async {
    try {
      await writeViaMain(port, 'folder', folder);
    } catch (e) {
      _failedBatches++;
      logger.e('CloudFileIsolate: folder write failed: $e');
    }
  }

  Future<void> _writeCursor(String collectionId, String? cursor) async {
    try {
      await writeViaMain(port, 'collectionChangeCursor', {
        'collectionId': collectionId,
        'cursor': cursor,
      });
    } catch (e) {
      logger.e('CloudFileIsolate: failed to store change cursor: $e');
    }
  }

  /// Relays source-side removals in chunks (SQLite bound-variable limit).
  Future<void> _writeRemovals(
    String collectionId,
    Set<String> itemIds,
    Set<String> parentIds,
    bool keepDeleted,
  ) async {
    const chunk = 400;
    final items = itemIds.toList();
    final parents = parentIds.toList();
    final rounds = [
      items.length,
      parents.length,
    ].reduce((a, b) => a > b ? a : b);
    for (var i = 0; i < rounds; i += chunk) {
      try {
        await writeViaMain(port, 'cloudRemovals', {
          'collectionId': collectionId,
          'itemIds': items.skip(i).take(chunk).toList(),
          'parentIds': parents.skip(i).take(chunk).toList(),
          'keepDeleted': keepDeleted,
          'at': DateTime.now(),
        });
      } catch (e) {
        _failedBatches++;
        logger.e('CloudFileIsolate: removal write failed: $e');
      }
    }
  }

  /// Applies the provider change feed since [cursor] and returns the cursor to
  /// store. Throws [CloudCursorExpiredException] if the provider rejects it.
  ///
  /// The feed is drive-wide, so every item is first checked against the
  /// collection: it is in scope when its parent is the collection root or a
  /// folder we already store (or one this same batch brings in). An item that
  /// leaves scope is treated as removed, and a folder that enters scope is
  /// walked because nothing under it has been stored yet.
  Future<({int count, String? newCursor})> _incrementalScan({
    required CloudFileApi api,
    required String collectionId,
    required String collectionPath,
    required String cursor,
    required bool keepDeleted,
    required DateTime scanStartTime,
  }) async {
    // 1. Drain the feed. Nothing is applied until it has been read to the end,
    // so an expired cursor mid-way leaves no half-applied state to reason about.
    final changes = <String, CloudChange>{}; // last change per id wins
    String? newCursor;
    String? next = cursor;
    while (next != null) {
      final page = await _retryNetworkOp(() => api.listChanges(next!));
      for (final c in page.changes) {
        changes.remove(c.id); // keep arrival order of the latest change
        changes[c.id] = c;
      }
      newCursor = page.newStartCursor ?? newCursor;
      next = page.nextPageCursor;
    }
    if (changes.isEmpty) return (count: 0, newCursor: newCursor);

    // 2. Scope. Drive reports the real root id in `parents`, while the
    // collection stores the 'root' alias.
    final realRootId =
        (await _retryNetworkOp(() => api.getEntry(collectionPath)))?.id;
    bool isRoot(String id) => id == collectionPath || id == realRootId;
    final known = await _knownFolders(collectionId);
    final scope = <String>{...known.keys};
    String? parentOf(CloudFileEntry e) =>
        e.parentIds.isNotEmpty ? e.parentIds.first : null;
    bool parentInScope(String? parent) =>
        parent != null && (isRoot(parent) || scope.contains(parent));

    // Folders first, to a fixpoint: a folder may arrive before its new parent.
    final folderChanges = [
      for (final c in changes.values)
        if (c.entry != null && c.entry!.isFolder) c.entry!,
    ];
    final acceptedFolders = <CloudFileEntry>[];
    var pending = folderChanges;
    var progressed = true;
    while (progressed && pending.isNotEmpty) {
      progressed = false;
      final still = <CloudFileEntry>[];
      for (final e in pending) {
        if (parentInScope(parentOf(e))) {
          scope.add(e.id);
          acceptedFolders.add(e);
          progressed = true;
        } else {
          still.add(e);
        }
      }
      pending = still;
    }

    final removedIds = <String>{}; // provider ids leaving the collection
    for (final c in changes.values) {
      if (c.removed) removedIds.add(c.id);
    }
    for (final e in pending) {
      removedIds.add(e.id); // folder moved out of (or never in) scope
    }

    int count = 0;
    final fileBatch = <File>[];
    final walkRoots = <String>[];
    final newlyInScope = <String>{
      for (final e in acceptedFolders)
        if (!known.containsKey(e.id)) e.id,
    };

    for (final e in acceptedFolders) {
      count++;
      final parent = parentOf(e)!;
      _folderNames[e.id] = e.name;
      _folderParents[e.id] = isRoot(parent) ? collectionPath : parent;
      await _writeFolder(
        _toFolder(
          entry: e,
          collectionId: collectionId,
          collectionPath: collectionPath,
          parentId: isRoot(parent) ? collectionPath : parent,
          scanStartTime: scanStartTime,
        ),
      );
      logger.i('Found NEW/CHANGED folder: ${e.name} (${e.id})');
      // Walk only the top of a new subtree; the BFS reaches the rest.
      if (newlyInScope.contains(e.id) && !newlyInScope.contains(parent)) {
        walkRoots.add(e.id);
      }
    }

    for (final c in changes.values) {
      final e = c.entry;
      if (c.removed || e == null || e.isFolder) continue;
      final parent = parentOf(e);
      if (!parentInScope(parent)) {
        removedIds.add(e.id); // moved out of scope
        continue;
      }
      count++;
      fileBatch.add(
        _toFile(
          api: api,
          entry: e,
          collectionId: collectionId,
          collectionPath: collectionPath,
          parentId: isRoot(parent!) ? collectionPath : parent,
          scanStartTime: scanStartTime,
        ),
      );
      logger.i('Found NEW/CHANGED file: ${e.name} (${e.id})');
      if (fileBatch.length >= _batchSize) await _flushBatch(fileBatch);
    }
    await _flushBatch(fileBatch);

    // 3. Removals. A removed folder takes everything stored beneath it.
    if (removedIds.isNotEmpty) {
      final goneFolders = <String>{
        for (final id in removedIds)
          if (known.containsKey(id)) id,
      };
      var grew = true;
      while (grew) {
        grew = false;
        known.forEach((id, parent) {
          if (goneFolders.contains(parent) && goneFolders.add(id)) grew = true;
        });
      }
      await _writeRemovals(
        collectionId,
        {
          for (final id in {...removedIds, ...goneFolders}) '$collectionId:$id',
        },
        goneFolders,
        keepDeleted,
      );
    }

    // 4. Folders that entered scope: nothing under them is stored yet.
    for (final id in walkRoots) {
      count += await _scanFolder(
        api: api,
        collectionId: collectionId,
        collectionPath: collectionPath,
        parentId: id,
        recursive: true,
        scanStartTime: scanStartTime,
      );
    }

    return (count: count, newCursor: newCursor);
  }

  /// Scans a cloud folder: breadth-first when [recursive], otherwise just the
  /// single folder. Files are batched in groups of [_batchSize] (same as
  /// [LocalFileIsolateWorker]).
  Future<int> _scanFolder({
    required CloudFileApi api,
    required String collectionId,
    required String collectionPath,
    required String parentId,
    required bool recursive,
    required DateTime scanStartTime,
  }) async {
    int count = 0;
    final fileBatch = <File>[];

    if (!recursive) {
      count += await _scanSingleFolder(
        api: api,
        collectionId: collectionId,
        collectionPath: collectionPath,
        parentId: parentId,
        scanStartTime: scanStartTime,
        fileBatch: fileBatch,
      );
    } else {
      final List<String> queue = [parentId];

      while (queue.isNotEmpty) {
        final currentFolderId = queue.removeAt(0);
        logger.i('CloudFileIsolate: BFS scanning folder ID: $currentFolderId');

        final discoveredFolders = <String>[];
        count += await _scanSingleFolder(
          api: api,
          collectionId: collectionId,
          collectionPath: collectionPath,
          parentId: currentFolderId,
          scanStartTime: scanStartTime,
          fileBatch: fileBatch,
          discoveredFolders: discoveredFolders,
        );

        queue.addAll(discoveredFolders);
      }
    }

    // Flush any remaining files
    await _flushBatch(fileBatch);
    return count;
  }

  /// Lists and writes items for a single cloud folder.
  Future<int> _scanSingleFolder({
    required CloudFileApi api,
    required String collectionId,
    required String collectionPath,
    required String parentId,
    required DateTime scanStartTime,
    required List<File> fileBatch,
    List<String>? discoveredFolders,
  }) async {
    int count = 0;
    String? pageToken;

    do {
      logger.d(
        'CloudFileIsolate: Fetching page of files for parent "$parentId" (pageToken: $pageToken)',
      );

      final page = await _retryNetworkOp(
        () => api.listChildren(parentId, pageToken: pageToken),
      );
      logger.d('CloudFileIsolate: Received ${page.entries.length} items');

      for (final e in page.entries) {
        if (e.isFolder) {
          _folderNames[e.id] = e.name;
          _folderParents[e.id] = parentId;

          await _writeFolder(
            _toFolder(
              entry: e,
              collectionId: collectionId,
              collectionPath: collectionPath,
              parentId: parentId,
              scanStartTime: scanStartTime,
            ),
          );
          logger.i('Found cloud folder: ${e.name} (${e.id})');
          discoveredFolders?.add(e.id);
        } else {
          count++;
          logger.i('Found cloud file: ${e.name} (${e.id})');
          fileBatch.add(
            _toFile(
              api: api,
              entry: e,
              collectionId: collectionId,
              collectionPath: collectionPath,
              parentId: parentId,
              scanStartTime: scanStartTime,
            ),
          );
          if (fileBatch.length >= _batchSize) await _flushBatch(fileBatch);
        }
      }

      pageToken = page.nextPageToken;
    } while (pageToken != null);

    return count;
  }

  // ---------------------------------------------------------------------------
  // Download Queue Processing
  // ---------------------------------------------------------------------------

  Future<void> _processQueue(
    CloudFileApi api,
    String appDir,
    String collectionName,
    String collectionPath,
  ) async {
    List<Future<void>> activeTasks = [];

    while (_downloadQueue.isNotEmpty || activeTasks.isNotEmpty) {
      // Pause if scanning is re-triggered
      if (_isScanning) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      while (_downloadQueue.isNotEmpty &&
          activeTasks.length < _maxConcurrentDownloads) {
        final file = _downloadQueue.removeAt(0);
        final task = _downloadFile(
          api,
          file,
          appDir,
          collectionName,
          collectionPath,
        );
        activeTasks.add(task);
        // Remove task from active list when done
        task.then((_) => activeTasks.remove(task));
      }

      if (activeTasks.isNotEmpty) {
        // Wait for at least one task to complete before checking again
        await Future.any(activeTasks);
      }
    }
  }

  // Thin delegate to the shared helper (scan_isolate_support.dart); the retry
  // logic is centralized there, call sites are unchanged.
  Future<T> _retryNetworkOp<T>(Future<T> Function() operation) =>
      retryNetworkOp(operation, logger: logger);

  Future<void> _downloadFile(
    CloudFileApi api,
    File file,
    String appDir,
    String collectionName,
    String collectionPath,
  ) async {
    int attempt = 0;
    const int maxRetries = 3;

    while (true) {
      attempt++;
      try {
        final remoteId = file.path.replaceFirst('${api.scheme}://', '');
        final relativePath = _reconstructPath(file.parent, collectionPath);
        final destDir = p.join(
          appDir,
          'files',
          api.scheme,
          collectionName,
          relativePath,
        );
        final destPath = p.join(destDir, file.name);

        final destFile = io.File(destPath);
        if (await destFile.exists()) {
          logger.d('File already exists on disk: $destPath');
          await writeViaMain(port, 'fileLocalPath', {
            'fileId': file.id,
            'localPath': destPath,
          });
          return;
        }

        await destFile.parent.create(recursive: true);
        logger.i(
          'Downloading: ${file.name} to $destPath (attempt $attempt/$maxRetries)',
        );

        // Write to a .part file and rename on success, so a failed transfer
        // can never be mistaken for a finished download.
        final part = io.File('$destPath.part');
        try {
          if (await part.exists()) await part.delete();
          await _retryNetworkOp(() => api.download(remoteId, part.path));
          await part.rename(destPath);
        } catch (_) {
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
          rethrow;
        }
        logger.i('Downloaded: ${file.name}');
        await writeViaMain(port, 'fileLocalPath', {
          'fileId': file.id,
          'localPath': destPath,
        });
        return; // Success!
      } catch (e) {
        final isTransient =
            e is io.IOException ||
            e is TimeoutException ||
            e.toString().contains('HandshakeException');
        if (isTransient && attempt < maxRetries) {
          final backoffMs = 1000 * attempt * attempt;
          logger.w(
            'Failed to download ${file.name} due to transient network error ($e). '
            'Retrying in ${backoffMs}ms...',
          );
          await Future.delayed(Duration(milliseconds: backoffMs));
          continue;
        }
        logger.e('Failed to download ${file.name} after $attempt attempts: $e');
        break; // Stop retrying on non-transient or exhausted retries
      }
    }
  }

  String _reconstructPath(String parentId, String collectionPath) {
    List<String> segments = [];
    String? currentId = parentId;

    while (currentId != null &&
        currentId.isNotEmpty &&
        currentId != collectionPath &&
        currentId != 'root') {
      String? name = _folderNames[currentId];
      if (name == null) break;
      segments.insert(0, name);
      currentId = _folderParents[currentId];
    }

    return p.joinAll(segments);
  }

  // ---------------------------------------------------------------------------
  // Model mapping helpers
  // ---------------------------------------------------------------------------

  Folder _toFolder({
    required CloudFileEntry entry,
    required String collectionId,
    required String collectionPath,
    required String parentId,
    required DateTime scanStartTime,
  }) {
    return Folder(
      // Stable ID: collision-safe using collectionId + provider item ID
      id: '$collectionId:${entry.id}',
      name: entry.name,
      // 'path' for cloud folders stores the provider item ID so it can be used
      // as a parentId in future API calls.
      path: entry.id,
      parent: parentId == collectionPath ? '' : parentId,
      dateCreated: entry.created ?? scanStartTime,
      dateLastModified: entry.modified ?? scanStartTime,
      lastScannedDate: scanStartTime,
      collectionId: collectionId,
      thumbnail: entry.thumbnailLink,
      downloadUrl: entry.webLink,
    );
  }

  File _toFile({
    required CloudFileApi api,
    required CloudFileEntry entry,
    required String collectionId,
    required String collectionPath,
    required String parentId,
    required DateTime scanStartTime,
  }) {
    return File(
      // Stable ID: collectionId + provider item ID (avoids path-based collisions)
      id: '$collectionId:${entry.id}',
      collectionId: collectionId,
      name: entry.name,
      // 'path' stores a URI-like reference: `<scheme>://<item id>`, so it's
      // distinguishable from local paths.
      path: '${api.scheme}://${entry.id}',
      parent: parentId == collectionPath ? '' : parentId,
      dateCreated: entry.created ?? scanStartTime,
      dateLastModified: entry.modified ?? scanStartTime,
      lastScannedDate: scanStartTime,
      isDeleted: false,
      size: entry.size ?? 0,
      contentHash: entry.contentHash,
      contentType: entry.mimeType ?? 'application/octet-stream',
      thumbnail: entry.thumbnailLink,
      downloadUrl: entry.webLink,
    );
  }
}
