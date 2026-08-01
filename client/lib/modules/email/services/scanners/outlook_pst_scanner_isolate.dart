import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/scanners/scan_isolate_support.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/services/vault_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/email/services/get_emails_service.dart';
import 'package:mydatastudio/modules/email/services/inline_attachment.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_generator.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/scan_write_relay.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';
import 'package:uuid/uuid.dart';

import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';

/// Whether [attPath] resolves inside [extractionRoot].
///
/// Compares normalized path components rather than a raw `startsWith` on the
/// canonicalized strings, so a sibling directory that merely shares the root
/// as a string prefix (e.g. `extraction-evil` vs `extraction`) isn't
/// mistaken for a path inside the root.
bool isPathWithinExtractionRoot(String attPath, String extractionRoot) {
  final canonicalAttPath = p.canonicalize(attPath);
  final canonicalRoot = p.canonicalize(extractionRoot);
  return canonicalAttPath == canonicalRoot ||
      p.isWithin(canonicalRoot, canonicalAttPath);
}

/// A snapshot of an in-flight PST import, for the UI to render.
///
/// A multi-gigabyte archive takes long enough that an unannotated spinner is
/// indistinguishable from a hang, so the parser reports its message total up
/// front and the worker relays its position against it.
class PstImportProgress {
  const PstImportProgress({
    required this.collectionId,
    required this.collectionName,
    this.totalMessages = 0,
    this.examined = 0,
    this.emails = 0,
    this.folder,
    this.done = false,
  });

  final String collectionId;
  final String collectionName;

  /// Messages the parser expects to examine, or 0 when it could not read the
  /// folder tree well enough to say — in which case there is no percentage and
  /// the UI falls back to an indeterminate bar.
  final int totalMessages;
  final int examined;

  /// Messages actually imported. Lower than [examined], because a PST folder
  /// also holds non-mail items the parser skips.
  final int emails;

  /// PST path of the folder being read, for a "what is it doing" line.
  final String? folder;
  final bool done;

  /// Fraction complete in 0..1, or null when the total is unknown.
  double? get fraction {
    if (totalMessages <= 0) return null;
    return (examined / totalMessages).clamp(0.0, 1.0);
  }

  PstImportProgress copyWith({
    int? totalMessages,
    int? examined,
    int? emails,
    String? folder,
    bool? done,
  }) {
    return PstImportProgress(
      collectionId: collectionId,
      collectionName: collectionName,
      totalMessages: totalMessages ?? this.totalMessages,
      examined: examined ?? this.examined,
      emails: emails ?? this.emails,
      folder: folder ?? this.folder,
      done: done ?? this.done,
    );
  }
}

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

  /// The import currently running, or null when none is. The import is started
  /// from the setup page but has to be reported on the email page, which is
  /// where the user lands as soon as it begins — hence a broadcast subject
  /// rather than a callback.
  static final BehaviorSubject<PstImportProgress?> importProgress =
      BehaviorSubject<PstImportProgress?>.seeded(null);

  /// Running totals per collection.
  ///
  /// [importProgress] only holds the most recent event, so it cannot be the
  /// place an import's own counters accumulate: with two archives importing at
  /// once, each report would `copyWith` onto whichever collection happened to
  /// report last. Keyed here instead, so interleaved imports stay independent.
  static final Map<String, PstImportProgress> _progressByCollection = {};

  /// The collection this instance is importing, so [stop] can close out its
  /// progress. Set by [start].
  String? _collectionId;

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

    _collectionId = collection.id;
    final initial = PstImportProgress(
      collectionId: collection.id,
      collectionName: collection.name,
    );
    _progressByCollection[collection.id] = initial;
    importProgress.add(initial);

    _isolate = await Isolate.spawn(OutlookPstScannerIsolateWorker.worker, args);

    final writeQueue = SequentialWriteQueue();

    receivePort.listen((message) {
      if (relayIsolateLog(logger, message, '[PstScan]')) return;
      if (message is Map) {
        if (message['type'] == 'dbWrite') {
          // Queued rather than awaited inline — see gmail_scanner_isolate.dart.
          // Matters even more here: PST streams thousands of unbatched writes,
          // so out-of-order processing would be far more likely to bite.
          final replyTo = message['replyTo'] as SendPort;
          writeQueue.add(() async {
            try {
              final result = await handleScanWriteMessage(message);
              replyTo.send({'ok': true, 'result': result});
            } catch (e) {
              replyTo.send({'ok': false, 'error': e.toString()});
            }
          });
          return;
        }
        if (message['type'] == 'refresh') {
          // Trigger UI refresh
          GetEmailsService.instance.invoke(
            EmailServiceCommand(collection, sortColumn: "date", sortAsc: false),
          );
        } else if (message['type'] == 'progress') {
          // Accumulate onto *this* collection's snapshot. Basing it on the
          // last globally-emitted value instead would drop every report from
          // the first import as soon as a second one started.
          final current = _progressByCollection[collection.id];
          if (current == null) return;
          final next = current.copyWith(
            totalMessages: (message['totalMessages'] as int?),
            examined: (message['examined'] as int?),
            emails: (message['emails'] as int?),
            folder: message['folder'] as String?,
            done: message['done'] as bool?,
          );
          _progressByCollection[collection.id] = next;
          importProgress.add(next);
        }
      }
    });
  }

  /// Immediately terminates the background isolate.
  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;

    // The worker is gone, so the `done` the UI is waiting for will never
    // arrive. Emit it here — otherwise a cancelled import leaves the progress
    // bar and the empty-list placeholder stalled on their last snapshot for
    // the rest of the session. `exitIncomplete` does the same for failures.
    final id = _collectionId;
    if (id == null) return;
    final current = _progressByCollection[id];
    if (current == null || current.done) return;
    final finished = current.copyWith(done: true);
    _progressByCollection[id] = finished;
    importProgress.add(finished);
  }
}

/// Entry point and logic for the PST background scan.
///
/// The worker runs in a separate isolate and communicates with the Python
/// FastAPI service via HTTP to parse the PST file.
class OutlookPstScannerIsolateWorker {
  /// Sends a write back to the main isolate and waits for its ack. See
  /// gmail_scanner_isolate.dart's `_writeViaMain` for the full rationale.
  static Future<Map<String, dynamic>> _writeViaMain(
    SendPort clientPort,
    String service,
    dynamic payload,
  ) async {
    final replyPort = ReceivePort();
    clientPort.send({
      'type': 'dbWrite',
      'service': service,
      'payload': payload,
      'replyTo': replyPort.sendPort,
    });
    final reply = await replyPort.first as Map;
    replyPort.close();
    if (reply['ok'] != true) {
      throw Exception('dbWrite($service) failed: ${reply['error']}');
    }
    return (reply['result'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  static Future<void> worker(Map<String, dynamic> workerArgs) async {
    runInScanIsolateZone(() async {
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

      final thumbnailCache = ThumbnailCache(appDir);

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
          await _writeViaMain(clientPort, 'collectionStatus', col);
        }
      }

      Future<Never> exitIncomplete(String error) async {
        await markStatus('incomplete');
        // Without this the progress banner would sit at 0% forever on a failure
        // that never reached the stream at all.
        clientPort.send({'type': 'progress', 'done': true});
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
      final request = http.Request(
        'POST',
        Uri.parse("$serverUrl/util/import/pst"),
      );
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
      // Every folder record as it was first upserted, keyed by PST path, so the
      // second pass below can rewrite it with a message count.
      final Map<String, EmailFolder> foldersByPath = {};
      // Emails actually imported per folder path. Deliberately *not* the parser's
      // `count`: that is the raw sub-message tally, which includes the free/busy
      // blocks and view definitions the parser skips. Only what we persisted
      // should decide whether a folder reads as empty in the UI.
      final Map<String, int> emailCountByPath = {};
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
      // Messages the parser said it would examine, from its opening 'start'
      // record. 0 means it couldn't read the tree; the UI shows an indeterminate
      // bar rather than a wrong percentage.
      int totalMessages = 0;

      // 3. Listen to stream output — use await-for to support async service calls
      try {
        await for (final line in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          try {
            if (line.trim().isEmpty) continue;
            final data = jsonDecode(line);

            if (data['type'] == 'start') {
              // Arrives before any folder or email, so the UI can show a real
              // percentage from the first update instead of switching partway.
              totalMessages = (data['total_messages'] as num?)?.toInt() ?? 0;
              clientPort.send({
                'type': 'progress',
                'totalMessages': totalMessages,
                'examined': 0,
                'emails': 0,
              });
            } else if (data['type'] == 'progress') {
              clientPort.send({
                'type': 'progress',
                'totalMessages': totalMessages,
                'examined': (data['examined'] as num?)?.toInt() ?? 0,
                // Emails the *client* persisted, not the parser's tally: a record
                // that failed to apply below is not in the archive the user ends
                // up with, and the count sits next to the progress bar.
                'emails': count,
                'folder': data['folder'] as String?,
              });
            } else if (data['type'] == 'folder') {
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
                    p.dirname(data['path']) == "" ||
                            p.dirname(data['path']) == "."
                        ? null
                        : folderPathToId[p.dirname(data['path'])],
              );

              foldersByPath[data['path']] = folder;
              await _writeViaMain(clientPort, 'emailFolder', folder);
            } else if (data['type'] == 'email') {
              final rawId = data['id'] as String? ?? 'unknown';
              final emailId = const Uuid().v5(
                Namespace.url.value,
                'email:pst:${collection.id}:$rawId',
              );
              final folderId = folderPathToId[data['folder']] ?? 'INBOX';

              final plainBody = data['body'] as String? ?? "";
              final snippet =
                  plainBody.length > 200
                      ? plainBody.substring(0, 200)
                      : plainBody;

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
                snippet: snippet,
                plainBody: plainBody,
                htmlBody: data['html_body'] ?? "",
                folderId: folderId,
                isRead: true,
                hasAttachments:
                    (data['attachments'] as List?)?.isNotEmpty ?? false,
                isDeleted: false,
              );

              await _writeViaMain(clientPort, 'emailBatch', [email]);

              final emailFolderPath = data['folder'] as String?;
              if (emailFolderPath != null) {
                emailCountByPath[emailFolderPath] =
                    (emailCountByPath[emailFolderPath] ?? 0) + 1;
              }

              // Process attachments — also emit Folder records so the file module
              // can navigate the directory tree (e.g., INBOX → 2010 → files).
              for (var att in data['attachments']) {
                final fileId = const Uuid().v5(
                  Namespace.url.value,
                  'file:pst:${collection.id}:$emailId:${att['name']}',
                );
                final attPath = att['path'] as String? ?? '';

                // Validate path stays within extraction root.
                if (attPath.isNotEmpty &&
                    !isPathWithinExtractionRoot(attPath, extractionRoot)) {
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
                    clientPort: clientPort,
                  );
                }

                final attContentType = _mapMimeType(
                  att['contentType'] as String? ?? 'application/octet-stream',
                );

                // The parser has already written the attachment to disk inside
                // extractionRoot, so this reads the extracted copy rather than
                // going back to the archive.
                String? thumbnail;
                if (attContentType == FilesConstants.mimeTypeImage &&
                    attPath.isNotEmpty) {
                  try {
                    thumbnail = await ThumbnailGenerator().generate(
                      collection.id,
                      fileId,
                      attPath,
                      FilesConstants.mimeTypeImage,
                      thumbnailCache,
                    );
                  } catch (e) {
                    logger.w(
                      'PST Scanner: Failed to generate thumbnail for $attPath: $e',
                    );
                  }
                }

                final file = File(
                  id: fileId,
                  name: att['name'],
                  path: attPath,
                  parent:
                      attPath.isNotEmpty ? p.dirname(attPath) : extractionRoot,
                  dateCreated: email.date,
                  dateLastModified: email.date,
                  collectionId: collection.id,
                  contentType: attContentType,
                  size: (att['size'] as num).toInt(),
                  isDeleted: false,
                  emailId: emailId,
                  thumbnail: thumbnail,
                  // Empty for an ordinary attachment; set only when the HTML body
                  // embeds this file as `<img src="cid:...">`.
                  contentId: InlineAttachment.normalizeContentId(
                    att['contentId'] as String?,
                  ),
                  // Decided here rather than in the parser so all four scanners
                  // share one rule. MAPI has no Content-Disposition, so a PST
                  // attachment is inline exactly when the body references it.
                  isInline: InlineAttachment.isInline(
                    contentId: att['contentId'] as String?,
                    fileName: att['name'] as String?,
                    htmlBody: email.htmlBody,
                  ),
                );
                await _writeViaMain(clientPort, 'file', file);
              }

              count++;
              if (count % 50 == 0) {
                clientPort.send({'type': 'refresh'});
              }
            } else if (data['type'] == 'debug') {
              final msg = data['message']?.toString() ?? '';
              logger.d(
                "PST Parser Debug: ${msg.length > 200 ? '${msg.substring(0, 200)}...' : msg}",
              );
            } else if (data['type'] == 'error') {
              errorCount++;
              final msg = data['message']?.toString() ?? '';
              logger.e(
                "PST Parser Error: ${msg.length > 200 ? '${msg.substring(0, 200)}...' : msg}",
              );
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
            // Never log the line itself: it is a whole parsed email, HTML body and
            // all, and a run where many fail (a stretch of SQLITE_BUSY, say) dumped
            // megabytes into the console — at error level, so each one also carried
            // a stack trace. Identify the message instead; the id is what you would
            // use to find it in the archive anyway.
            logger.e("PST Isolate: ${_describeLine(line)}. Error: $e");
          }
        }
      } catch (e) {
        // The HTTP stream itself failed partway (dropped connection, server
        // died). Whatever was upserted persists, but the import didn't finish.
        streamFailed = true;
        logger.e("PST Isolate: Stream failed mid-import: $e");
      }

      // 4. Second pass: stamp each folder with the number of emails it holds,
      // counting its whole subtree. This can only run once the stream is done,
      // because a folder's children stream in after the folder itself.
      //
      // The rollup is what makes "empty" mean the right thing in the sidebar. A
      // PST archive routinely has container folders that hold no mail directly
      // but parent everything that does (in mnimer_digitalchef.pst, all 1181
      // emails sit under a `non-Allaire Email` folder with zero of its own).
      // Counting only direct messages would hide exactly the folders the user
      // needs to navigate through.
      await _writeFolderCounts(
        foldersByPath: foldersByPath,
        emailCountByPath: emailCountByPath,
        clientPort: clientPort,
      );

      // 5. Cleanup. A PST import is only 'complete' when the parser's end-of-walk
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

      // Sent before the refresh so the UI drops the progress banner in the same
      // frame it repaints the list, rather than flashing a stalled bar over it.
      clientPort.send({
        'type': 'progress',
        'totalMessages': totalMessages,
        'examined': totalMessages,
        'emails': count,
        'done': true,
      });
      clientPort.send({'type': 'refresh'});
      Isolate.exit(clientPort, {'done': true});
    });
  }

  /// Describes a stream line for an error message, without quoting its content.
  ///
  /// An email record carries the full plain-text *and* HTML body, so logging
  /// the raw line is what turned a run of failures into megabytes of console
  /// output. The identifying fields are bounded in size and are what you would
  /// actually search the archive by; the byte length stands in when the line
  /// isn't decodable JSON at all.
  static String _describeLine(String line) {
    try {
      final data = jsonDecode(line);
      if (data is Map) {
        final type = data['type'] ?? 'unknown';
        if (type == 'email') {
          return "failed to apply email id=${data['id']} in '${data['folder']}'";
        }
        if (type == 'folder') {
          return "failed to apply folder '${data['path']}'";
        }
        return "failed to apply a '$type' record";
      }
    } catch (_) {
      // Falls through: an undecodable line is exactly the case where there are
      // no fields to name.
    }
    return "failed to decode a ${line.length}-byte line";
  }

  /// Re-upserts every imported folder with `messagesTotal` set to the number of
  /// emails in that folder **and all of its descendants**.
  ///
  /// A folder's subtree is identified by path prefix rather than by walking
  /// `parentId`, because the paths are what the parser streams and they are
  /// already the key both maps are built on. Folder counts are in the tens, so
  /// the nested scan costs nothing.
  static Future<void> _writeFolderCounts({
    required Map<String, EmailFolder> foldersByPath,
    required Map<String, int> emailCountByPath,
    required SendPort clientPort,
  }) async {
    for (final entry in foldersByPath.entries) {
      final path = entry.key;
      final folder = entry.value;

      // `path + separator` matters: without it, a sibling folder named
      // `Inbox2` would be counted as part of `Inbox`.
      final prefix = '$path${p.separator}';
      int total = 0;
      emailCountByPath.forEach((emailPath, count) {
        if (emailPath == path || emailPath.startsWith(prefix)) {
          total += count;
        }
      });

      await _writeViaMain(
        clientPort,
        'emailFolder',
        EmailFolder(
          id: folder.id,
          collectionId: folder.collectionId,
          name: folder.name,
          type: folder.type,
          messagesTotal: total,
          messagesUnread: folder.messagesUnread,
          parentId: folder.parentId,
        ),
      );
    }
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
    required SendPort clientPort,
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
      await _writeViaMain(clientPort, 'folder', folder);
    }
  }
}
