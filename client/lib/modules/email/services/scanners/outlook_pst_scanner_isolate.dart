import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/modules/email/services/get_emails_service.dart';
import 'package:mydatatools/modules/files/files_constants.dart';
import 'package:uuid/uuid.dart';

import 'package:http/http.dart' as http;

class OutlookPstScannerIsolate {
  final RootIsolateToken? token;
  final SendPort? dbWriterPort;
  final String appDir;
  final String serverUrl;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  OutlookPstScannerIsolate({
    this.token,
    this.dbWriterPort,
    required this.appDir,
    required this.serverUrl,
  });

  Future<void> start(Collection collection, {bool force = false}) async {
    if (dbWriterPort == null) {
      throw Exception("dbWriterPort is required for OutlookPstScannerIsolate");
    }

    ReceivePort receivePort = ReceivePort("OutlookPstScannerIsolateClient");

    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'port': receivePort.sendPort,
      'dbWriterPort': dbWriterPort,
      'collection': collection,
      'appDir': appDir,
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

  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

class OutlookPstScannerIsolateWorker {
  static Future<void> worker(Map<String, dynamic> workerArgs) async {
    final RootIsolateToken? token = workerArgs['token'];
    final SendPort clientPort = workerArgs['port'];
    final SendPort dbWriterPort = workerArgs['dbWriterPort'];
    final Collection collection = workerArgs['collection'];
    final String appDir = workerArgs['appDir'];
    final String? serverUrl = workerArgs['serverUrl'];

    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);

    // 1. Prepare extraction root for attachments
    // Using a folder relative to the collection name in the storage workspace
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
    final request = http.Request('POST', Uri.parse("$serverUrl/import/pst"));
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

    // Keep track of internal IDs
    final Map<String, String> folderPathToId = {};
    // Track directories already emitted as Folder records for the file module.
    final Set<String> emittedFolderPaths = {};
    int count = 0;

    // 3. Listen to stream output
    await response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            if (line.trim().isEmpty) return;
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
                    p.dirname(data['path']) == "" ||
                            p.dirname(data['path']) == "."
                        ? null
                        : folderPathToId[p.dirname(data['path'])],
              );

              dbWriterPort.send({'type': 'email_folder', 'folder': folder});
            } else if (data['type'] == 'email') {
              final emailId = const Uuid().v4();
              final folderId = folderPathToId[data['folder']] ?? 'INBOX';

              final email = Email(
                id: emailId,
                collectionId: collection.id,
                date: DateTime.tryParse(data['date'] ?? "") ?? DateTime.now(),
                from: data['sender'] ?? "Unknown",
                to:
                    (data['to'] as List?)?.map((e) => e.toString()).toList() ??
                    [],
                cc:
                    (data['cc'] as List?)?.map((e) => e.toString()).toList() ??
                    [],
                subject: data['subject'] ?? "(No Subject)",
                plainBody: data['body'] ?? "",
                htmlBody: data['html_body'] ?? "",
                folderId: folderId,
                isRead: true,
                hasAttachments:
                    (data['attachments'] as List?)?.isNotEmpty ?? false,
                isDeleted: false,
              );

              dbWriterPort.send({
                'type': 'batch_email',
                'emails': [email],
              });

              // Process attachments — also emit Folder records so the file module
              // can navigate the directory tree (e.g., INBOX → 2010 → files).
              for (var att in data['attachments']) {
                final fileId = const Uuid().v4();
                final attPath = att['path'] as String? ?? '';

                // Validate path stays within extraction root
                if (attPath.isNotEmpty &&
                    !p.canonicalize(attPath).startsWith(p.canonicalize(extractionRoot))) {
                  logger.w('PST Scanner: Skipping attachment with path outside extraction root');
                  continue;
                }

                // Ensure every directory level from extractionRoot down to the
                // attachment's parent has a Folder record in the file module DB.
                if (attPath.isNotEmpty) {
                  _ensureFolderPath(
                    attPath: attPath,
                    extractionRoot: extractionRoot,
                    collectionId: collection.id,
                    emailDate: email.date,
                    emittedFolderPaths: emittedFolderPaths,
                    dbWriterPort: dbWriterPort,
                  );
                }

                final file = File(
                  id: fileId,
                  name: att['name'],
                  path: attPath,
                  // Use p.dirname(attPath) so the file lives under its
                  // INBOX/2010 sub-folder within the extraction root.
                  // This makes it browsable when the file module opens at
                  // extractionRoot.
                  parent:
                      attPath.isNotEmpty ? p.dirname(attPath) : extractionRoot,
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
                dbWriterPort.send({'type': 'file', 'file': file});
              }

              count++;
              if (count % 50 == 0) {
                // Refresh rate of 50 emails keeps UI updates visible without
                // hammering the main thread with DB queries.
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
        })
        .asFuture();

    // 4. Cleanup
    logger.i(
      "PST Scanner: Finished processing stream. Processed $count emails.",
    );

    // Update collection status
    dbWriterPort.send({
      'type': 'update_collection_status',
      'id': collection.id,
      'status': 'complete',
      'lastScan': DateTime.now().toIso8601String(),
    });

    clientPort.send({'type': 'refresh'});
    Isolate.exit(clientPort, {'done': true});
  }

  /// Maps a standard MIME type (e.g. "image/jpeg") to the internal
  /// [FilesConstants] value used throughout the app.  Falls back to
  /// [FilesConstants.mimeTypeUnKnown] if the type is not recognised.
  static String _mapMimeType(String mimeType) {
    if (mimeType.startsWith('image/')) return FilesConstants.mimeTypeImage;
    if (mimeType.startsWith('video/')) return FilesConstants.mimeTypeMovie;
    if (mimeType.startsWith('audio/')) return FilesConstants.mimeTypeMusic;
    if (mimeType == 'application/pdf') return FilesConstants.mimeTypePdf;
    return FilesConstants.mimeTypeUnKnown;
  }

  /// Ensures every directory level from [extractionRoot] down to the parent
  /// of [attPath] has a [Folder] record in the file-module database.
  ///
  /// Works by collecting all ancestor paths (exclusive of extractionRoot itself,
  /// since the file module already browses from there) and emitting a
  /// `{'type': 'folder', 'folder': Folder}` message for each one that hasn't
  /// been emitted yet.  Paths already in [emittedFolderPaths] are skipped to
  /// avoid duplicate inserts.
  static void _ensureFolderPath({
    required String attPath,
    required String extractionRoot,
    required String collectionId,
    required DateTime emailDate,
    required Set<String> emittedFolderPaths,
    required SendPort dbWriterPort,
  }) {
    // Build the list of ancestor dirs between extractionRoot and attPath's
    // parent, ordered from shallowest to deepest.
    final List<String> dirs = [];
    String current = p.dirname(attPath);
    while (current != extractionRoot && current.startsWith(extractionRoot)) {
      dirs.insert(0, current); // prepend so we go top-down
      final up = p.dirname(current);
      if (up == current) break; // filesystem root guard
      current = up;
    }
    // Also include extractionRoot itself so the first level is visible.
    dirs.insert(0, extractionRoot);

    for (final dirPath in dirs) {
      if (emittedFolderPaths.contains(dirPath)) continue;
      emittedFolderPaths.add(dirPath);

      final parentPath = p.dirname(dirPath);
      final folder = Folder(
        id: '$collectionId:$dirPath',
        name: p.basename(dirPath),
        path: dirPath,
        // extractionRoot has the collection.id as its notional parent, which
        // keeps it anchored to the collection without a real parent record.
        parent: parentPath == dirPath ? collectionId : parentPath,
        dateCreated: emailDate,
        dateLastModified: emailDate,
        collectionId: collectionId,
      );
      dbWriterPort.send({'type': 'folder', 'folder': folder});
    }
  }
}
