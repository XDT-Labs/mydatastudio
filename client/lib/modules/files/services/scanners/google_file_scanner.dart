import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/oauth/google_auth_client.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';
import 'package:logger/logger.dart';

/// Scanner lifecycle manager for cloud-based file sources (Google Drive, etc.).
///
/// Extends [CollectionScanner] — the same base used by [LocalFileIsolate] —
/// but instead of reading the local filesystem it uses a [FileSourceProvider]
/// reconstructed *inside* the isolate from raw token strings.
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
  final SendPort dbWriterIsolatePort;
  Isolate? _isolate;
  AppLogger? _logger;

  CloudFileIsolate(this.loggerIsolatePort, this.dbWriterIsolatePort) : super() {
    _logger = AppLogger(loggerIsolatePort);
  }

  @override
  Future<int> start(
    Collection collection,
    String? path,
    bool recursive,
    bool force,
  ) async {
    isScanning.add(true);
    final String debugName = 'CloudFileIsolate_${collection.id}';

    final ReceivePort p = ReceivePort(debugName);
    final token = RootIsolateToken.instance!;

    // Only pass isolate-safe primitives across the boundary
    final Map<String, dynamic> args = {
      'token': token,
      'port': p.sendPort,
      'dbWriterPort': dbWriterIsolatePort,
      'loggerPort': p.sendPort, // Send logs back through our own ReceivePort
      'collectionId': collection.id,
      'collectionName': collection.name,
      // The root folder ID to start scanning from (e.g. 'root' or a specific folder ID)
      'rootFolderId': path ?? collection.path,
      'isFullScan': path == null || path == collection.path,
      'recursive': recursive,
      // Raw token strings — the worker re-creates the API client inside the isolate
      'providerKey': collection.scanner,
      'accessToken': collection.accessToken,
      'refreshToken': collection.refreshToken,
      'accessTokenExpiry': collection.expiration?.toIso8601String(),
    };

    _isolate = await Isolate.spawn<Map<String, dynamic>>(
      CloudFileIsolateWorker._entry,
      args,
      debugName: debugName,
    );
    _isolate!.addOnExitListener(p.sendPort);

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
    _logger?.w('CloudFileIsolate stopped');
  }
}

// ---------------------------------------------------------------------------
// Isolate worker — runs entirely inside the spawned isolate
// ---------------------------------------------------------------------------

/// All execution inside the Drive isolate. Receives raw token strings and
/// rebuilds the Drive API client before scanning.
class CloudFileIsolateWorker {
  final SendPort dbWriterPort;
  final SendPort? loggerPort;
  late final AppLogger logger;

  CloudFileIsolateWorker(this.dbWriterPort, this.loggerPort) {
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

      final worker = CloudFileIsolateWorker(
        args['dbWriterPort'] as SendPort,
        loggerPort,
      );

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
    final rootFolderId = args['rootFolderId'] as String? ?? 'root';
    final isFullScan = args['isFullScan'] as bool? ?? false;
    final recursive = args['recursive'] as bool? ?? true;
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
        final result = await GoogleDriveAuthService.refreshTokens(
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
    final driveApi = drive.DriveApi(
      GoogleAuthClient({'Authorization': 'Bearer $validToken'}),
    );

    logger.i(
      'CloudFileIsolate: starting scan of "$collectionName" from folder "$rootFolderId"',
    );

    final scanStartTime = DateTime.now();

    try {
      final count = await _scanFolder(
        driveApi: driveApi,
        collectionId: collectionId,
        parentId: rootFolderId,
        recursive: recursive,
        scanStartTime: scanStartTime,
      );

      logger.i(
        'CloudFileIsolate: scan complete — $count items for "$collectionName"',
      );

      // Signal the DB writer to mark anything not seen this scan as deleted
      final ReceivePort syncPort = ReceivePort();
      dbWriterPort.send({
        'type': 'cleanup_deleted',
        'collectionId': collectionId,
        'path': rootFolderId,
        'scanStartTime': scanStartTime,
        'recursive': recursive,
        'isCloud': true,
        'isFullScan': isFullScan,
        'replyTo': syncPort.sendPort,
      });
      await syncPort.first;
      syncPort.close();
    } catch (e, stack) {
      logger.e(
        'CloudFileIsolate: scan error for "$collectionName": $e\n$stack',
      );
    }

    Isolate.exit(args['port'] as SendPort, 0);
  }

  /// Recursively scans a Drive folder.
  ///
  /// Files are batched in groups of 100 before being sent to the DB writer
  /// (same batch size as [LocalFileIsolateWorker]).
  Future<int> _scanFolder({
    required drive.DriveApi driveApi,
    required String collectionId,
    required String parentId,
    required bool recursive,
    required DateTime scanStartTime,
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
          // Persist folder first so the UI can show the tree
          final folder = _toFolder(
            collectionId: collectionId,
            parentId: parentId,
            driveFile: f,
            scanStartTime: scanStartTime,
          );
          if (folder != null) {
            dbWriterPort.send({'type': 'folder', 'folder': folder});
            logger.i('Found Drive folder: ${f.name} (${f.id})');

            if (recursive) {
              logger.s('Google Drive: $folder.name');
              count += await _scanFolder(
                driveApi: driveApi,
                collectionId: collectionId,
                parentId: f.id!,
                recursive: recursive,
                scanStartTime: scanStartTime,
                currentBatch: fileBatch,
              );
            }
          }
        } else {
          count++;
          final file = _toFile(
            collectionId: collectionId,
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
              dbWriterPort.send({
                'type': 'batch_file',
                'files': List<File>.from(fileBatch),
              });
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
      dbWriterPort.send({
        'type': 'batch_file',
        'files': List<File>.from(fileBatch),
      });
      fileBatch.clear();
    }

    return count;
  }

  // ---------------------------------------------------------------------------
  // Model mapping helpers
  // ---------------------------------------------------------------------------

  Folder? _toFolder({
    required String collectionId,
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
      parent: parentId,
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
      parent: parentId,
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
