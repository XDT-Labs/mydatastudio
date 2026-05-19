import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/file_sources/google_drive/google_auth_service.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/modules/files/services/batch_file_upsert_service.dart';
import 'package:mydatatools/modules/files/services/cleanup_deleted_files_service.dart';
import 'package:mydatatools/modules/files/services/folder_upsert_service.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;

/// Scanner lifecycle manager for cloud-based file sources (Google Drive, etc.).
///
/// Extends [CollectionScanner] — the same base used by [LocalFileIsolate] —
/// but instead of reading the local filesystem it uses a [FileSourceProvider]
/// reconstructed *inside* the isolate from raw token strings.
///
/// Synchronization Rules:
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
///
/// ## Why reconstruct instead of passing the provider object?
/// Dart isolates do not share memory. Only primitive types, [SendPort]s, and
/// types that implement [Isolate]-safe serialisation can cross the boundary.
/// A `GoogleDriveProvider` holds a live `http.Client` and logger which cannot
/// be transferred. Instead we pass raw strings (providerKey, accessToken,
/// refreshToken) and rebuild the provider inside.
///
/// ## Message protocol with [DbIsolateWriter]
/// Uses the same `batch_file` / `folder` / `cleanup_deleted` messages as
/// [LocalFileIsolate] — no changes to the DB writer are needed.
class CloudFileIsolate extends CollectionScanner {
  final SendPort? loggerIsolatePort;
  final String? storagePath;
  final String? dbName;
  Isolate? _isolate;
  AppLogger? _logger;

  CloudFileIsolate(this.loggerIsolatePort, {this.storagePath, this.dbName}) : super() {
    _logger = AppLogger(loggerIsolatePort);
  }

  /// Starts the cloud file scanning process.
  ///
  /// [collection] The cloud collection to scan.
  /// [path] Mode selector:
  ///   - If NULL: **Full Sync**. Exhaustively traverses the entire cloud collection root.
  ///   - If NOT NULL: **Targeted Scan**. Focuses ONLY on the specified folder ID
  ///     (e.g., Google Drive folder ID) for immediate results during navigation.
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
      _logger?.i("Registration-only mode: skipping scan for ${collection.name}");
      return 0;
    }

    if (force) {
      stop();
    }

    isScanning.add(true);
    final String debugName = 'CloudFileIsolate_${collection.id}';

    final ReceivePort p = ReceivePort(debugName);
    final token = RootIsolateToken.instance!;

    final String? actualPath =
        (path != null && path.isNotEmpty) ? path : collection.path;

    // Only pass isolate-safe primitives across the boundary
    final Map<String, dynamic> args = {
      'token': token,
      'port': p.sendPort,
      'storagePath': storagePath,
      'dbName': dbName,
      'loggerPort': p.sendPort, // Send logs back through our own ReceivePort
      'collectionId': collection.id,
      'collectionName': collection.name,
      'collectionPath': collection.path,
      'lastScanDate': collection.lastScanDate?.toIso8601String(),
      'downloadLocalCopy': collection.downloadLocalCopy,
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
    };

    _isolate = await spawnIsolate(
      CloudFileIsolateWorker._entry,
      args,
      debugName: debugName,
    );
    _isolate?.addOnExitListener(p.sendPort);

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
        } else if (type == 'scan_complete') {
          // The initial scan is done, but the isolate might stay alive for downloads.
          // For now, we allow start() to return so ScannerManager is unblocked.
          // But we don't break the loop if we want to keep listening for logs from the worker.
          isScanning.add(false);
        }
      }
    }

    isScanning.add(false);
    p.close();
    return 0;
  }

  @override
  void stop() {
    _isolate?.kill(priority: Isolate.beforeNextEvent);
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

/// All execution inside the Drive isolate. Receives raw token strings and
/// rebuilds the Drive API client before scanning.
class CloudFileIsolateWorker {
  final AppDatabase appDb;
  final SendPort? loggerPort;
  late final AppLogger logger;

  // Caches for path reconstruction
  final Map<String, String> _folderNames = {};
  final Map<String, String> _folderParents = {};

  // Download management
  final List<File> _downloadQueue = [];
  static const int _maxConcurrentDownloads = 3;
  bool _isScanning = false;

  CloudFileIsolateWorker(this.appDb, this.loggerPort) {
    logger = AppLogger(loggerPort);
  }

  // Top-level isolate entry — must be a static or top-level function.
  static Future<void> _entry(Map<String, dynamic> args) async {
    final SendPort? loggerPort = args['loggerPort'] as SendPort?;
    try {
      // Set log level inside the isolate
      Logger.level = Level.debug;

      final token = args['token'] as RootIsolateToken;
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);

      final appDb = await AppDatabase.create(
        null,
        args['storagePath'] as String,
        args['dbName'] as String,
        false,
      );

      final worker = CloudFileIsolateWorker(appDb, loggerPort);

      await worker._scan(args);
    } catch (e, stack) {
      // If we can't even start the worker, send a log if possible, otherwise print
      if (loggerPort != null) {
        loggerPort.send({
          'type': 'log',
          'level': 'error',
          'message': 'CRITICAL: CloudFileIsolate failed to start: $e',
          'stackTrace': stack.toString(),
        });
      }
      print('CRITICAL: CloudFileIsolate failed to start: $e\n$stack');
      Isolate.exit(args['port'] as SendPort, 1);
    }
  }

  Future<void> _scan(Map<String, dynamic> args) async {
    final collectionId = args['collectionId'] as String;
    final collectionName = args['collectionName'] as String;
    final collectionPath = args['collectionPath'] as String? ?? 'root';
    final rootFolderId = args['rootFolderId'] as String? ?? 'root';
    final lastScanDateStr = args['lastScanDate'] as String?;
    final lastScanDate = lastScanDateStr != null ? DateTime.tryParse(lastScanDateStr) : null;
    final storagePath = args['storagePath'] as String?;
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

    // Dart flow-analysis doesn't recognise Isolate.exit() as a terminator,
    // so we use local non-nullable bindings instead of the ! operator.
    if (accessToken == null || refreshToken == null) {
      logger.e(
        'CloudFileIsolate: no tokens for collection "$collectionName" — aborting scan',
      );
      Isolate.exit(args['port'] as SendPort, 0);
    }
    final String safeAccessToken = accessToken;
    final String safeRefreshToken = refreshToken;

    // Refresh token if near expiry before scanning starts
    String validToken = safeAccessToken;
    final now = DateTime.now().toUtc();
    final nearExpiry =
        expiry == null ||
        now.isAfter(expiry.subtract(const Duration(minutes: 5)));

    if (nearExpiry) {
      try {
        logger.i('CloudFileIsolate: refreshing token for "$collectionName"');
        final result = await GoogleAuthService.refreshTokens(
          accessToken: safeAccessToken,
          refreshToken: safeRefreshToken,
        );
        validToken = result.accessToken;
        logger.i('CloudFileIsolate: token refreshed');
      } catch (e) {
        logger.e(
          'CloudFileIsolate: token refresh failed for "$collectionName": $e',
        );
        Isolate.exit(args['port'] as SendPort, 0);
      }
    }

    // Build Drive API client from refreshed token
    final driveApi = drive.DriveApi(AuthenticatedHttpClient.bearer(validToken));

    final scanStartTime = DateTime.now();
    _isScanning = true;

    try {
      int count = 0;
      bool skipCleanup = false;

      // Rule Selection:
      // If it's a full scan (root), and not forced, and we have a lastScanDate
      // then we perform an incremental metadata sync using modifiedTime.
      if (isFullScan && !force && lastScanDate != null) {
        logger.i(
          'CloudFileIsolate: Performing INCREMENTAL sync for "$collectionName" (since $lastScanDate)',
        );
        count = await _incrementalScan(
          driveApi: driveApi,
          collectionId: collectionId,
          collectionPath: collectionPath,
          lastScanDate: lastScanDate,
          scanStartTime: scanStartTime,
        );
        // We skip cleanup_deleted because incremental sync only sees changes,
        // and doesn't know about missing items.
        skipCleanup = true;
      } else {
        logger.i(
          'CloudFileIsolate: Starting RECURSIVE scan of "$collectionName" from folder "$rootFolderId" (force=$force)',
        );
        count = await _scanFolder(
          driveApi: driveApi,
          collectionId: collectionId,
          collectionPath: collectionPath,
          parentId: rootFolderId,
          recursive: recursive,
          scanStartTime: scanStartTime,
          downloadLocalCopy: downloadLocalCopy,
        );
      }

      logger.i(
        'CloudFileIsolate: scan complete — $count items for "$collectionName"',
      );

      if (!skipCleanup) {
        // Mark anything not seen this scan as deleted (full walks / forced refreshes)
        await CleanupDeletedFilesService.instance.invoke(
          CleanupDeletedFilesServiceCommand(
            collectionId,
            rootFolderId == collectionPath ? '' : rootFolderId,
            scanStartTime,
            appDb,
            recursive: recursive,
            isCloud: true,
            isFullScan: isFullScan,
          ),
        );
      }

      // Update lastScanDate in the DB
      final colRepo = CollectionRepository(appDb);
      final col = await colRepo.collectionById(collectionId);
      if (col != null) {
        col.scanStatus = 'ready';
        col.lastScanDate = scanStartTime;
        await colRepo.updateCollection(col);
      }

      _isScanning = false;
      (args['port'] as SendPort).send({'type': 'scan_complete'});

      if (downloadLocalCopy && storagePath != null) {
        // Query DB for files with null localPath
        logger.i('CloudFileIsolate: querying DB for files needing download...');
        final List<File> allFilesNeedingDownload =
            await FileDesktopRepository(appDb).getFilesToDownload(collectionId);
        _downloadQueue.clear();

        // Filter out Google native formats (Docs, Sheets, etc.) that we can't download as full media
        for (final file in allFilesNeedingDownload) {
          if (!_isGoogleNativeFormat(file.contentType)) {
            _downloadQueue.add(file);
          }
        }

        logger.i(
          'CloudFileIsolate: processing download queue (${_downloadQueue.length} items)',
        );
        await _processQueue(
          driveApi,
          storagePath,
          collectionName,
          collectionPath,
        );

      }
    } catch (e, stack) {
      logger.e(
        'CloudFileIsolate: scan error for "$collectionName": $e\n$stack',
      );
    }

    Isolate.exit(args['port'] as SendPort, 0);
  }

  /// Performs an incremental metadata sync using Drive's modifiedTime query.
  /// Finds all items modified since [lastScanDate].
  Future<int> _incrementalScan({
    required drive.DriveApi driveApi,
    required String collectionId,
    required String collectionPath,
    required DateTime lastScanDate,
    required DateTime scanStartTime,
  }) async {
    int count = 0;
    final fileBatch = <File>[];
    String? pageToken;

    // We use a query like: modifiedTime > '2023-01-01T00:00:00Z' and trashed = false
    // Note: If collectionPath is not 'root', this query might still return items outside the collection
    // but the mapping helpers handle filtering by checking parent IDs against known DB folder IDs.
    final String rfc3339Date = lastScanDate.toUtc().toIso8601String();
    String query = "modifiedTime > '$rfc3339Date' and trashed = false";
    
    // If we are restricted to a specific subfolder, we can try to scoped it, 
    // but cross-folder moves make global queries safer for catch-up.
    // For now, we trust the DB upsert logic to handle items correctly.

    do {
      final response = await driveApi.files.list(
        q: query,
        $fields:
            'nextPageToken, files(id, name, mimeType, size, createdTime, modifiedTime, parents, thumbnailLink, webContentLink)',
        pageToken: pageToken,
        pageSize: 100,
      );

      final files = response.files ?? [];
      for (final f in files) {
        if (f.id == null) continue;
        count++;

        final isFolder = f.mimeType == 'application/vnd.google-apps.folder';
        final parentId = (f.parents != null && f.parents!.isNotEmpty) ? f.parents!.first : 'root';

        if (isFolder) {
          final folder = _toFolder(
            collectionId: collectionId,
            collectionPath: collectionPath,
            parentId: parentId,
            driveFile: f,
            scanStartTime: scanStartTime,
          );
          if (folder != null) {
            await FolderUpsertService.instance.invoke(
              FolderUpsertServiceCommand(folder, appDb),
            );
            logger.i('Found NEW/CHANGED folder: ${f.name} (${f.id})');
          }
        } else {
          final file = _toFile(
            collectionId: collectionId,
            collectionPath: collectionPath,
            parentId: parentId,
            driveFile: f,
            scanStartTime: scanStartTime,
          );
          if (file != null) {
            fileBatch.add(file);
            logger.i('Found NEW/CHANGED file: ${f.name} (${f.id})');

            if (fileBatch.length >= 100) {
              await BatchFileUpsertService.instance.invoke(
                BatchFileUpsertServiceCommand(List<File>.from(fileBatch), appDb),
              );
              fileBatch.clear();
            }
          }
        }
      }
      pageToken = response.nextPageToken;
    } while (pageToken != null);

    if (fileBatch.isNotEmpty) {
      await BatchFileUpsertService.instance.invoke(
        BatchFileUpsertServiceCommand(List<File>.from(fileBatch), appDb),
      );
    }

    return count;
  }

  /// Recursively scans a Drive folder.
  ///
  /// Files are batched in groups of 100 before being sent to the DB writer
  /// (same batch size as [LocalFileIsolateWorker]).
  Future<int> _scanFolder({
    required drive.DriveApi driveApi,
    required String collectionId,
    required String collectionPath,
    required String parentId,
    required bool recursive,
    required DateTime scanStartTime,
    bool downloadLocalCopy = false,
    List<File>? currentBatch,
  }) async {
    int count = 0;
    final fileBatch = currentBatch ?? <File>[];
    String? pageToken;

    do {
      logger.d(
        'CloudFileIsolate: Fetching page of files for parent "$parentId" (pageToken: $pageToken)',
      );

      final response = await driveApi.files.list(
        q: "'$parentId' in parents and trashed = false",
        $fields:
            'nextPageToken, files(id, name, mimeType, size, createdTime, modifiedTime, parents, thumbnailLink, webContentLink)',
        pageToken: pageToken,
        pageSize: 200,
        orderBy: 'folder, name',
      );

      final files = response.files ?? [];
      logger.d(
        'CloudFileIsolate: Received ${files.length} items from Drive API',
      );

      for (final f in files) {
        if (f.id == null) continue;

        final isFolder = f.mimeType == 'application/vnd.google-apps.folder';

        if (isFolder) {
          _folderNames[f.id!] = f.name ?? 'Untitled Folder';
          _folderParents[f.id!] = parentId;

          final folder = _toFolder(
            collectionId: collectionId,
            collectionPath: collectionPath,
            parentId: parentId,
            driveFile: f,
            scanStartTime: scanStartTime,
          );
          if (folder != null) {
            await FolderUpsertService.instance.invoke(
              FolderUpsertServiceCommand(folder, appDb),
            );
            logger.i('Found Drive folder: ${f.name} (${f.id})');

            if (recursive) {
              logger.s('Google Drive: $folder.name');
              count += await _scanFolder(
                driveApi: driveApi,
                collectionId: collectionId,
                collectionPath: collectionPath,
                parentId: f.id!,
                recursive: recursive,
                scanStartTime: scanStartTime,
                downloadLocalCopy: downloadLocalCopy,
                currentBatch: fileBatch,
              );
            }
          }
        } else {
          count++;
          final file = _toFile(
            collectionId: collectionId,
            collectionPath: collectionPath,
            parentId: parentId,
            driveFile: f,
            scanStartTime: scanStartTime,
          );
          if (file != null) {
            logger.i('Found Drive file: ${f.name} (${f.id})');
            fileBatch.add(file);
            
            if (fileBatch.length >= 100) {
              logger.d(
                'CloudFileIsolate: Sending batch of ${fileBatch.length} files to DB writer',
              );
              await BatchFileUpsertService.instance.invoke(
                BatchFileUpsertServiceCommand(List<File>.from(fileBatch), appDb),
              );
              fileBatch.clear();
            }
          }
        }
      }

      pageToken = response.nextPageToken;
    } while (pageToken != null);

    // Flush any remaining files when returning from the top-level call
    if (currentBatch == null && fileBatch.isNotEmpty) {
      logger.d(
        'CloudFileIsolate: Sending final batch of ${fileBatch.length} files to DB writer',
      );
      await BatchFileUpsertService.instance.invoke(
        BatchFileUpsertServiceCommand(List<File>.from(fileBatch), appDb),
      );
      fileBatch.clear();
    }

    return count;
  }

  // ---------------------------------------------------------------------------
  // Download Queue Processing
  // ---------------------------------------------------------------------------

  Future<void> _processQueue(drive.DriveApi driveApi, String storagePath, String collectionName, String collectionPath) async {
    List<Future<void>> activeTasks = [];
    
    while (_downloadQueue.isNotEmpty || activeTasks.isNotEmpty) {
      // Pause if scanning is re-triggered
      if (_isScanning) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      while (_downloadQueue.isNotEmpty && activeTasks.length < _maxConcurrentDownloads) {
        final file = _downloadQueue.removeAt(0);
        final task = _downloadFile(driveApi, file, storagePath, collectionName, collectionPath);
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

  Future<void> _downloadFile(drive.DriveApi driveApi, File file, String storagePath, String collectionName, String collectionPath) async {
    try {
      final driveId = file.path.replaceFirst('gdrive://', '');
      final relativePath = _reconstructPath(file.parent, collectionPath);
      final destDir = p.join(storagePath, 'files', 'gdrive', collectionName, relativePath);
      final destPath = p.join(destDir, file.name);

      final destFile = io.File(destPath);
      if (await destFile.exists()) {
        logger.d('File already exists on disk: $destPath');
        await appDb.execute(
          'UPDATE files SET local_path = ? WHERE id = ?',
          [destPath, file.id],
        );
        return;
      }

      await destFile.parent.create(recursive: true);
      logger.i('Downloading: ${file.name} to $destPath');

      final drive.Media media = await driveApi.files.get(
        driveId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final sink = destFile.openWrite();
      try {
        await media.stream.pipe(sink);
        logger.i('Downloaded: ${file.name}');
        await appDb.execute(
          'UPDATE files SET local_path = ? WHERE id = ?',
          [destPath, file.id],
        );
      } finally {
        await sink.flush();
        await sink.close();
      }
    } catch (e) {
      logger.e('Failed to download ${file.name}: $e');
    }
  }

  String _reconstructPath(String parentId, String collectionPath) {
    List<String> segments = [];
    String? currentId = parentId;
    
    while (currentId != null && currentId.isNotEmpty && currentId != collectionPath && currentId != 'root') {
      String? name = _folderNames[currentId];
      if (name == null) break;
      segments.insert(0, name);
      currentId = _folderParents[currentId];
    }
    
    return p.joinAll(segments);
  }

  bool _isGoogleNativeFormat(String mimeType) {
    return mimeType.startsWith('application/vnd.google-apps.') &&
        mimeType != 'application/vnd.google-apps.folder';
  }

  // ---------------------------------------------------------------------------
  // Model mapping helpers
  // ---------------------------------------------------------------------------

  Folder? _toFolder({
    required String collectionId,
    required String collectionPath,
    required String parentId,
    required drive.File driveFile,
    required DateTime scanStartTime,
  }) {
    if (driveFile.id == null || driveFile.name == null) return null;

    return Folder(
      // Stable ID: collision-safe using collectionId + Drive file ID
      id: '$collectionId:${driveFile.id}',
      name: driveFile.name!,
      // 'path' for cloud folders stores the Drive file ID so it can be used
      // as a parentId in future API calls.
      path: driveFile.id!,
      parent: parentId == collectionPath ? '' : parentId,
      dateCreated: driveFile.createdTime ?? scanStartTime,
      dateLastModified: driveFile.modifiedTime ?? scanStartTime,
      lastScannedDate: scanStartTime,
      collectionId: collectionId,
      thumbnail: driveFile.thumbnailLink,
      downloadUrl: driveFile.webContentLink,
    );
  }

  File? _toFile({
    required String collectionId,
    required String collectionPath,
    required String parentId,
    required drive.File driveFile,
    required DateTime scanStartTime,
  }) {
    if (driveFile.id == null || driveFile.name == null) return null;

    final sizeStr = driveFile.size;
    final size = sizeStr != null ? int.tryParse(sizeStr) ?? 0 : 0;

    return File(
      // Stable ID: collectionId + Drive file ID (avoids path-based collisions)
      id: '$collectionId:${driveFile.id}',
      collectionId: collectionId,
      name: driveFile.name!,
      // 'path' stores a URI-like reference. For cloud files this is the Drive
      // file ID prefixed with 'gdrive://' so it's distinguishable from local paths.
      path: 'gdrive://${driveFile.id}',
      parent: parentId == collectionPath ? '' : parentId,
      dateCreated: driveFile.createdTime ?? scanStartTime,
      dateLastModified: driveFile.modifiedTime ?? scanStartTime,
      lastScannedDate: scanStartTime,
      isDeleted: false,
      size: size,
      contentType: driveFile.mimeType ?? 'application/octet-stream',
      thumbnail: driveFile.thumbnailLink,
      downloadUrl: driveFile.webContentLink,
    );
  }
}
