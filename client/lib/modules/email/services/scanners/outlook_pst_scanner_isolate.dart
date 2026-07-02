import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/email/services/email_folder_upsert_service.dart';
import 'package:mydatastudio/modules/email/services/email_upsert_service.dart';
import 'package:mydatastudio/modules/email/services/get_emails_service.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/file_upsert_service.dart';
import 'package:mydatastudio/modules/files/services/folder_upsert_service.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:uuid/uuid.dart';

import 'package:http/http.dart' as http;

/// [OutlookPstScannerIsolate] is the client-side manager for the Outlook PST
/// scanning background isolate. It handles spawning the worker, which calls
/// the Python FastAPI service to parse the PST file and stream results back.
///
/// Synchronization Rules:
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
class OutlookPstScannerIsolate {
  final RootIsolateToken? token;
  final String appDir;
  final String serverUrl;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  final String dbDir;

  OutlookPstScannerIsolate({
    this.token,
    required this.appDir,
    required this.dbDir,
    required this.serverUrl,
  });

  /// Spawns the PST background worker isolate.
  ///
  /// [collection] The PST collection to synchronize.
  /// [force] If false, returns immediately (Rule 2).
  ///
  /// Note: PST scanners currently default to a **Full Sync** of the entire
  /// archive. Targeted scanning of specific PST folders is not yet implemented.
  Future<void> start(Collection collection, {bool force = false}) async {
    if (!force) {
      logger.i("Registration-only mode: skipping scan for ${collection.name}");
      return;
    }

    ReceivePort receivePort = ReceivePort("OutlookPstScannerIsolateClient");

    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'port': receivePort.sendPort,
      'collection': collection,
      'appDir': appDir,
      'dbDir': dbDir,
      'serverUrl': serverUrl,
    };

    _isolate = await Isolate.spawn(OutlookPstScannerIsolateWorker.worker, args);

    receivePort.listen((message) {
      if (message is Map) {
        if (message['type'] == 'refresh') {
          // Trigger UI refresh
          GetEmailsService.instance.invoke(
            EmailServiceCommand(collection, sortColumn: "date", sortAsc: false),
          );
        }
      }
    });
  }

  /// Immediately terminates the background isolate.
  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

/// Entry point and logic for the PST background scan.
///
/// The worker runs in a separate isolate and communicates with the Python
/// FastAPI service via HTTP to parse the PST file.
class OutlookPstScannerIsolateWorker {
  static Future<void> worker(Map<String, dynamic> workerArgs) async {
    final RootIsolateToken? token = workerArgs['token'];
    final SendPort clientPort = workerArgs['port'];
    final Collection collection = workerArgs['collection'];
    final String appDir = workerArgs['appDir'];
    final String dbDir = workerArgs['dbDir'] ?? appDir;
    final String? serverUrl = workerArgs['serverUrl'];

    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);

    // 1. Prepare extraction root for attachments
    final extractionRoot = p.join(appDir, 'files', 'email', collection.id);
    if (!io.Directory(extractionRoot).existsSync()) {
      io.Directory(extractionRoot).createSync(recursive: true);
    }

    logger.i(
      "PST Scanner: Started parsing ${collection.path} -> $extractionRoot",
    );

    if (serverUrl == null) {
      logger.e("PST Scanner: serverUrl is missing!");
      Isolate.exit(clientPort, {'error': 'missing_server_url'});
    }

    // 2. Call FastAPI endpoint
    logger.i("PST Scanner: Calling AI Chat API for PST import");

    final client = http.Client();
    final request = http.Request('POST', Uri.parse("$serverUrl/util/import/pst"));
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'file_path': collection.path,
      'output_dir': extractionRoot,
    });

    final response = await client.send(request);

    if (response.statusCode != 200) {
      logger.e("PST Scanner: API failed with status ${response.statusCode}");
      Isolate.exit(clientPort, {'error': 'api_failed'});
    }

    final appDb = await AppDatabase.create(null, dbDir, AppConstants.dbName);

    // Keep track of internal IDs
    final Map<String, String> folderPathToId = {};
    // Track directories already emitted as Folder records for the file module.
    final Set<String> emittedFolderPaths = {};
    int count = 0;

    // 3. Listen to stream output — use await-for to support async service calls
    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      try {
        if (line.trim().isEmpty) continue;
        final data = jsonDecode(line);

        if (data['type'] == 'folder') {
          final folderId = const Uuid().v4();
          folderPathToId[data['path']] = folderId;

          logger.d(
            "PST Folder: ${data['name']} (Path: ${data['path']}, Messages: ${data['count']})",
          );

          final folder = EmailFolder(
            id: folderId,
            collectionId: collection.id,
            name: data['name'],
            type: 'user',
            parentId:
                p.dirname(data['path']) == "" || p.dirname(data['path']) == "."
                    ? null
                    : folderPathToId[p.dirname(data['path'])],
          );

          await EmailFolderUpsertService.instance.invoke(
            EmailFolderUpsertServiceCommand(folder, appDb),
          );
        } else if (data['type'] == 'email') {
          final emailId = const Uuid().v4();
          final folderId = folderPathToId[data['folder']] ?? 'INBOX';

          final email = Email(
            id: emailId,
            collectionId: collection.id,
            date: DateTime.tryParse(data['date'] ?? "") ?? DateTime.now(),
            from: data['sender'] ?? "Unknown",
            to: (data['to'] as List?)?.map((e) => e.toString()).toList() ?? [],
            cc: (data['cc'] as List?)?.map((e) => e.toString()).toList() ?? [],
            subject: data['subject'] ?? "(No Subject)",
            plainBody: data['body'] ?? "",
            htmlBody: data['html_body'] ?? "",
            folderId: folderId,
            isRead: true,
            hasAttachments: (data['attachments'] as List?)?.isNotEmpty ?? false,
            isDeleted: false,
          );

          await EmailUpsertService.instance.invoke(
            EmailUpsertServiceCommand([email], appDb),
          );

          // Process attachments — also emit Folder records so the file module
          // can navigate the directory tree (e.g., INBOX → 2010 → files).
          for (var att in data['attachments']) {
            final fileId = const Uuid().v4();
            final attPath = att['path'] as String? ?? '';

            // Validate path stays within extraction root
            if (attPath.isNotEmpty &&
                !p
                    .canonicalize(attPath)
                    .startsWith(p.canonicalize(extractionRoot))) {
              logger.w(
                'PST Scanner: Skipping attachment with path outside extraction root',
              );
              continue;
            }

            // Ensure every directory level from extractionRoot down to the
            // attachment's parent has a Folder record in the file module DB.
            if (attPath.isNotEmpty) {
              await _ensureFolderPath(
                attPath: attPath,
                extractionRoot: extractionRoot,
                collectionId: collection.id,
                emailDate: email.date,
                emittedFolderPaths: emittedFolderPaths,
                appDb: appDb,
              );
            }

            final file = File(
              id: fileId,
              name: att['name'],
              path: attPath,
              parent: attPath.isNotEmpty ? p.dirname(attPath) : extractionRoot,
              dateCreated: email.date,
              dateLastModified: email.date,
              collectionId: collection.id,
              contentType: _mapMimeType(
                att['contentType'] as String? ?? 'application/octet-stream',
              ),
              size: (att['size'] as num).toInt(),
              isDeleted: false,
              emailId: emailId,
            );
            await FileUpsertService.instance.invoke(
              FileUpsertServiceCommand(file, appDb),
            );
          }

          count++;
          if (count % 50 == 0) {
            clientPort.send({'type': 'refresh'});
          }
        } else if (data['type'] == 'debug') {
          logger.d("PST Parser Debug: ${data['message']}");
        } else if (data['type'] == 'error') {
          logger.e("PST Parser Error: ${data['message']}");
        }
      } catch (e) {
        logger.e("PST Isolate: Failed to parse line: $line. Error: $e");
      }
    }

    // 4. Cleanup
    logger.i(
      "PST Scanner: Finished processing stream. Processed $count emails.",
    );

    // Update collection status
    final collectionRepo = CollectionRepository(appDb);
    final col = await collectionRepo.collectionById(collection.id);
    if (col != null) {
      col.scanStatus = 'complete';
      col.lastScanDate = DateTime.now();
      await collectionRepo.updateCollection(col);
    }

    clientPort.send({'type': 'refresh'});
    Isolate.exit(clientPort, {'done': true});
  }

  /// Maps a standard MIME type (e.g. "image/jpeg") to the internal
  /// [FilesConstants] value used throughout the app.
  static String _mapMimeType(String mimeType) {
    if (mimeType.startsWith('image/')) return FilesConstants.mimeTypeImage;
    if (mimeType.startsWith('video/')) return FilesConstants.mimeTypeMovie;
    if (mimeType.startsWith('audio/')) return FilesConstants.mimeTypeMusic;
    if (mimeType == 'application/pdf') return FilesConstants.mimeTypePdf;
    return FilesConstants.mimeTypeUnKnown;
  }

  /// Ensures every directory level from [extractionRoot] down to the parent
  /// of [attPath] has a [Folder] record in the file-module database.
  static Future<void> _ensureFolderPath({
    required String attPath,
    required String extractionRoot,
    required String collectionId,
    required DateTime emailDate,
    required Set<String> emittedFolderPaths,
    required AppDatabase appDb,
  }) async {
    final List<String> dirs = [];
    String current = p.dirname(attPath);
    while (current != extractionRoot && current.startsWith(extractionRoot)) {
      dirs.insert(0, current); // prepend so we go top-down
      final up = p.dirname(current);
      if (up == current) break; // filesystem root guard
      current = up;
    }
    dirs.insert(0, extractionRoot);

    for (final dirPath in dirs) {
      if (emittedFolderPaths.contains(dirPath)) continue;
      emittedFolderPaths.add(dirPath);

      final parentPath = p.dirname(dirPath);
      final folder = Folder(
        id: '$collectionId:$dirPath',
        name: p.basename(dirPath),
        path: dirPath,
        parent: parentPath == dirPath ? collectionId : parentPath,
        dateCreated: emailDate,
        dateLastModified: emailDate,
        collectionId: collectionId,
      );
      await FolderUpsertService.instance.invoke(
        FolderUpsertServiceCommand(folder, appDb),
      );
    }
  }
}
