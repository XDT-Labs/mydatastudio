import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/scanners/scan_isolate_support.dart';
import 'package:mydatastudio/database_manager.dart';import 'package:mydatastudio/services/vault_manager.dart';
import 'package:mydatastudio/main.dart';
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
/// scanning background isolate. It spawns the worker, which calls the Python
/// FastAPI service to parse the PST file and stream results back.
///
/// **PST is the exception to the standard scanner contract.** Unlike the live
/// email providers (Gmail/Outlook/Yahoo), a `.pst` is a local file this app
/// neither owns nor watches — there is no change feed to poll. Outlook may
/// still write to the file, so rather than try to reconcile that, each selected
/// PST is treated as a **one-shot snapshot**: imported whole when the user
/// picks it, never refreshed afterwards. Consequently PST:
///
///   * is a **one-shot import**, run exactly once when the collection is added
///     (see `NewEmailPage._import`), and is **not** registered in
///     `ScannerManager` (it throws there by design);
///   * has **no re-sync and no targeted folder scan** — those affordances are
///     intentionally hidden in the UI (the folder Refresh icon and the account
///     "Sync" menu item), so the generic `path == null` / `path != null`
///     contract does not apply here;
///   * is re-imported only by **deleting the collection and re-selecting the
///     file** — there is no incremental update path.
///
/// Because there is no second chance, the single import pass tracks a
/// completion summary and marks the collection `complete` only when the
/// parser's end-of-walk summary arrives with zero errors; otherwise it is left
/// `incomplete` for the UI to surface (see the worker below). See the
/// "targeted PST-folder scanning" resolution in AUDIT.md.
class OutlookPstScannerIsolate {
  final RootIsolateToken? token;
  final String appDir;
  final String serverUrl;
  final String? serverToken;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  final String dbDir;

  OutlookPstScannerIsolate({
    this.token,
    required this.appDir,
    required this.dbDir,
    required this.serverUrl,
    this.serverToken,
  });

  /// Spawns the PST background worker isolate to import [collection] once.
  ///
  /// [force] guards against an accidental no-op call; the sole caller
  /// (`NewEmailPage._import`) passes `force: true`. There is deliberately no
  /// folder/path parameter — a PST archive is imported whole, one time, and is
  /// never re-synced or folder-targeted (see the class doc).
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
      'serverToken': serverToken,
      // DEK so the worker can decrypt/encrypt collection tokens (AUDIT M2 ph4).
      'vaultDek': VaultManager.instance.dek,
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
    final String? serverToken = workerArgs['serverToken'];

    // Init platform channels + install the credential vault (AUDIT M2 phase 4).
    bootstrapScanIsolate(token, workerArgs['vaultDek'] as Uint8List?);

    final AppLogger logger = AppLogger(clientPort);

    // 1. Prepare extraction root for attachments
    final extractionRoot = p.join(appDir, 'files', 'email', collection.id);
    if (!io.Directory(extractionRoot).existsSync()) {
      io.Directory(extractionRoot).createSync(recursive: true);
    }

    logger.i(
      "PST Scanner: Started parsing ${collection.path} -> $extractionRoot",
    );

    // Opened before the request so every exit path — including the failures
    // below — can record a terminal status. A PST is never re-synced, so a
    // collection left at its initial 'pending' would stay that way forever.
    final appDb = await AppDatabase.create(null, dbDir, AppConstants.dbName);

    Future<void> markStatus(String status) async {
      final repo = CollectionRepository(appDb);
      final col = await repo.collectionById(collection.id);
      if (col != null) {
        col.scanStatus = status;
        col.lastScanDate = DateTime.now();
        await repo.updateCollection(col);
      }
    }

    Future<Never> exitIncomplete(String error) async {
      await markStatus('incomplete');
      clientPort.send({'type': 'refresh'});
      Isolate.exit(clientPort, {'error': error});
    }

    if (serverUrl == null) {
      logger.e("PST Scanner: serverUrl is missing!");
      await exitIncomplete('missing_server_url');
    }

    // 2. Call FastAPI endpoint
    logger.i("PST Scanner: Calling AI Chat API for PST import");

    final client = http.Client();
    final request = http.Request('POST', Uri.parse("$serverUrl/util/import/pst"));
    request.headers['Content-Type'] = 'application/json';
    request.headers.addAll(aiServerAuthHeaders(serverToken));
    request.body = jsonEncode({
      'file_path': collection.path,
      'output_dir': extractionRoot,
    });

    // A refused/dropped connection is the same class of failure as a non-200:
    // the import never ran, and the collection must not be left pending.
    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } catch (e) {
      logger.e("PST Scanner: request to the aiserver failed: $e");
      await exitIncomplete('api_failed');
    }

    if (response.statusCode != 200) {
      logger.e("PST Scanner: API failed with status ${response.statusCode}");
      await exitIncomplete('api_failed');
    }

    // Keep track of internal IDs
    final Map<String, String> folderPathToId = {};
    // Track directories already emitted as Folder records for the file module.
    final Set<String> emittedFolderPaths = {};
    int count = 0;
    // Completion tracking. PST is a one-shot import with no re-sync, so we only
    // mark the collection 'complete' when the parser's end-of-walk summary
    // arrived AND nothing failed; otherwise it's 'incomplete' and the user is
    // told to delete + re-add (see status update below).
    int errorCount = 0;
    int summaryErrors = 0;
    bool sawSummary = false;
    bool streamFailed = false;

    // 3. Listen to stream output — use await-for to support async service calls
    try {
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        try {
        if (line.trim().isEmpty) continue;
        final data = jsonDecode(line);

        if (data['type'] == 'folder') {
          final folderId = const Uuid().v5(
            Namespace.url.value,
            'folder:pst:${collection.id}:${data['path']}',
          );
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
          final rawId = data['id'] as String? ?? 'unknown';
          final emailId = const Uuid().v5(
            Namespace.url.value,
            'email:pst:${collection.id}:$rawId',
          );
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
            final fileId = const Uuid().v5(
              Namespace.url.value,
              'file:pst:${collection.id}:$emailId:${att['name']}',
            );
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
          errorCount++;
          logger.e("PST Parser Error: ${data['message']}");
        } else if (data['type'] == 'summary') {
          sawSummary = true;
          // Cross-check against our own tally: the parser's count is
          // authoritative for errors it hit, ours for lines we failed to
          // apply. Either being non-zero means the import isn't whole.
          summaryErrors = (data['errors'] as num?)?.toInt() ?? 0;
          logger.i(
            "PST Parser Summary: folders=${data['folders']} "
            "emails=${data['emails']} errors=${data['errors']}",
          );
        }
      } catch (e) {
        // A line we couldn't decode/persist is lost data — count it so the
        // import is flagged incomplete rather than silently truncated.
        errorCount++;
        logger.e("PST Isolate: Failed to parse line: $line. Error: $e");
      }
      }
    } catch (e) {
      // The HTTP stream itself failed partway (dropped connection, server
      // died). Whatever was upserted persists, but the import didn't finish.
      streamFailed = true;
      logger.e("PST Isolate: Stream failed mid-import: $e");
    }

    // 4. Cleanup. A PST import is only 'complete' when the parser's end-of-walk
    // summary arrived AND nothing failed; anything else is 'incomplete'.
    final clean =
        sawSummary && !streamFailed && errorCount == 0 && summaryErrors == 0;
    logger.i(
      "PST Scanner: Finished. Processed $count emails "
      "(errors=$errorCount, parserErrors=$summaryErrors, "
      "sawSummary=$sawSummary, streamFailed=$streamFailed) "
      "→ ${clean ? 'complete' : 'incomplete'}.",
    );

    // Update collection status. 'incomplete' is terminal for a PST — there is
    // no re-sync — so the UI surfaces it and the user re-imports by deleting the
    // collection and selecting the file again.
    await markStatus(clean ? 'complete' : 'incomplete');

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
