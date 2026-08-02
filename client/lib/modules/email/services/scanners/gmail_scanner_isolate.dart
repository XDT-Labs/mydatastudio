import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:googleapis/gmail/v1.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/scanners/scan_isolate_support.dart';
import 'package:mydatastudio/services/vault_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/email/services/email_decoding_helper.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/email/services/get_emails_service.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/email/services/inline_attachment.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_generator.dart';
import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/scan_write_relay.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';
import 'package:uuid/uuid.dart';

/// [GmailScannerIsolate] is the client-side manager for the Gmail scanning
/// background isolate. It handles spawning the worker, parameter propagation,
/// and bidirectional communication during the sync process.
///
/// Synchronization Rules:
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
class GmailScannerIsolate {
  final RootIsolateToken? token;
  final String appDir;
  final String dbDir;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  GmailScannerIsolate({this.token, required this.appDir, required this.dbDir});

  /// Spawns the Gmail background worker isolate.
  ///
  /// [collection] The collection to synchronize.
  /// [folderId] Mode selector:
  ///   - If NULL: **Full Sync**. Synchronizes all labels/folders.
  ///   - If NOT NULL: **Targeted Scan**. Focuses ONLY on the specified label ID
  ///     (e.g., 'INBOX', 'Sent').
  /// [force] If false, returns immediately (Rule 2).
  /// [statusPort] Optional port to receive status/heartbeat messages.
  Future<void> start(
    Collection collection, {
    String? folderId,
    bool force = false,
    SendPort? statusPort,
  }) async {
    if (!force) {
      logger.i("Registration-only mode: skipping scan for ${collection.name}");
      return;
    }

    ReceivePort receivePort = ReceivePort("GmailScannerIsolateClient");

    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'port': receivePort.sendPort,
      'collection': collection,
      'folderId': folderId,
      'lastScanDate': collection.lastScanDate?.toIso8601String(),
      'force': force,
      'appDir': appDir,
      'dbDir': dbDir,
      // DEK for the credential vault so in-isolate collection reads/writes and
      // token refresh can decrypt/encrypt secrets (AUDIT M2 phase 4).
      'vaultDek': VaultManager.instance.dek,
    };

    _isolate = await spawnIsolate(GmailScannerIsolateWorker.worker, args);

    final writeQueue = SequentialWriteQueue();

    receivePort.listen((message) {
      // Checked before the statusPort forward below: a dbWrite carries a live
      // replyTo SendPort and the full File/Email/Folder payload being
      // written, neither of which statusPort's listener (scan status and
      // progress only) should ever see.
      if (message is Map && message['type'] == 'dbWrite') {
        // Queued rather than awaited inline: this listener callback isn't
        // awaited by the port itself, so without an explicit queue, writes
        // could be handled out of order (a file landing before its folder).
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

      // Forward status messages if requested
      if (statusPort != null) {
        statusPort.send(message);
      }

      // Replayed after the forward above so statusPort still sees every message.
      if (relayIsolateLog(logger, message, '[GmailScan]')) return;

      if (message is Map) {
        if (message['type'] == 'refresh') {
          GetEmailsService.instance.invoke(
            EmailServiceCommand(
              collection,
              sortColumn: "date",
              sortAsc: false,
              folderId: folderId,
            ),
          );
        }
      }
    });

    // Make sure we update once on start if it was idle
    if (statusPort != null) {
      statusPort.send({'status': 'scanning'});
    }
  }

  /// Immediately terminates the background isolate.
  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  /// Overridable for testing to avoid real isolate spawning
  Future<Isolate?> spawnIsolate(
    Function(Map<String, dynamic>) entryPoint,
    Map<String, dynamic> args,
  ) async {
    return await Isolate.spawn(entryPoint, args);
  }
}

/// Entry point and logic for the Gmail background scan.
///
/// The worker runs in a separate isolate, opens its own AppDatabase connection,
/// and writes results directly via upsert services.
class GmailScannerIsolateWorker {
  static Future<void> worker(Map<String, dynamic> args) async {
    runInScanIsolateZone(() async {
      final RootIsolateToken? token = args['token'];
      final SendPort clientPort = args['port'];
      final Collection collection = args['collection'];
      final String? folderId = args['folderId'];
      final String? lastScanDateStr = args['lastScanDate'];
      final DateTime? lastScanDate =
          lastScanDateStr != null ? DateTime.tryParse(lastScanDateStr) : null;
      final bool force = args['force'] ?? false;
      final String appDir = args['appDir'];
      final String dbDir = args['dbDir'] ?? appDir;

      // Init platform channels + install the credential vault (AUDIT M2 phase 4)
      // so in-isolate collection reads/writes and token refresh can decrypt
      // secrets. Without the vault, decrypting the collection tokens fails.
      bootstrapScanIsolate(token, args['vaultDek'] as Uint8List?);

      final AppLogger logger = AppLogger(clientPort);

      // Validate tokens exist before attempting refresh or API calls.
      // Dart flow-analysis doesn't recognise Isolate.exit() as a terminator,
      // so we use local non-nullable bindings instead of the ! operator.
      final accessTokenRaw = collection.accessToken;
      final refreshTokenRaw = collection.refreshToken;
      if (accessTokenRaw == null || refreshTokenRaw == null) {
        logger.e(
          'GmailScannerIsolate: no tokens for "${collection.name}" — aborting scan',
        );
        Isolate.exit(clientPort, {'error': 'auth_failed'});
      }
      final String safeAccessToken = accessTokenRaw;
      final String safeRefreshToken = refreshTokenRaw;

      // Refresh token if near expiry using consolidated auth service
      String accessToken = safeAccessToken;
      try {
        if (GoogleAuthService.isTokenExpired(collection.expiration)) {
          final result = await GoogleAuthService.refreshTokens(
            accessToken: safeAccessToken,
            refreshToken: safeRefreshToken,
          );
          accessToken = result.accessToken;
        }
      } catch (e) {
        logger.e("Failed to validate Gmail token: $e");
        Isolate.exit(clientPort, {'error': 'auth_failed'});
      }

      final appDb = await AppDatabase.create(null, dbDir, AppConstants.dbName);

      final authHttpClient = AuthenticatedHttpClient.bearer(accessToken);
      final GmailApi gmailApi = GmailApi(authHttpClient);

      try {
        // 1. Sync Labels (Folders)
        logger.s("Syncing Gmail labels...");
        final labelsResponse = await _retryNetworkOp(
          () => gmailApi.users.labels.list('me'),
          logger,
        );
        final labels = labelsResponse.labels ?? [];

        for (var label in labels) {
          final folder = mapLabelToFolder(label, collection.id);
          await writeViaMain(clientPort, 'emailFolder', folder);
        }

        final scanStartTime = DateTime.now();
        int totalFound = 0;
        int newEmails = 0;
        int skipped = 0;

        // 2. Sync Emails
        if (folderId != null) {
          logger.s("Syncing folder: $folderId");
          final results = await _pullEmails(
            gmailApi,
            appDb,
            clientPort,
            collection,
            appDir,
            accessToken,
            labelId: folderId,
            lastScanDate: lastScanDate,
            force: force,
          );
          totalFound += results['total'] ?? 0;
          newEmails += results['new'] ?? 0;
          skipped += results['skipped'] ?? 0;
        } else {
          // Default sync: Inbox, Sent, Trash, Spam
          const defaultLabels = ['INBOX', 'SENT', 'TRASH', 'SPAM'];
          for (var label in defaultLabels) {
            logger.s("Syncing label: $label");
            final results = await _pullEmails(
              gmailApi,
              appDb,
              clientPort,
              collection,
              appDir,
              accessToken,
              labelId: label,
              lastScanDate: lastScanDate,
              force: force,
            );
            totalFound += results['total'] ?? 0;
            newEmails += results['new'] ?? 0;
            skipped += results['skipped'] ?? 0;
          }
        }

        logger.i(
          "Gmail sync complete: $totalFound found, $newEmails new, $skipped skipped.",
        );

        // Update lastScanDate in the DB. The read stays on this isolate's own
        // connection; only the write goes back to main.
        final collectionRepo = CollectionRepository(appDb);
        final col = await collectionRepo.collectionById(collection.id);
        if (col != null) {
          col.scanStatus = 'ready';
          col.lastScanDate = scanStartTime;
          await writeViaMain(clientPort, 'collectionStatus', col);
        }

        clientPort.send({'type': 'refresh', 'status': 'done'});
      } catch (e, stack) {
        logger.e("Error in Gmail Isolate: $e", error: e, stackTrace: stack);
      } finally {
        Isolate.exit(clientPort, {'status': 'done'});
      }
    });
  }

  static Future<Map<String, int>> _pullEmails(
    GmailApi gmailApi,
    AppDatabase appDb,
    SendPort clientPort,
    Collection collection,
    String appDir,
    String accessToken, {
    String? labelId,
    String? pageToken,
    DateTime? lastScanDate,
    bool force = false,
  }) async {
    final logger = AppLogger(clientPort);
    int total = 0;
    int newCount = 0;
    int skippedCount = 0;

    String? query;
    if (!force && lastScanDate != null) {
      // Gmail search query 'after:' uses seconds since epoch or YYYY/MM/DD
      // Using seconds (Unix timestamp) is most precise.
      final seconds = lastScanDate.millisecondsSinceEpoch ~/ 1000;
      query = 'after:$seconds';
      logger.i("Gmail: Performing incremental sync ($query)");
    }

    final response = await _retryNetworkOp(
      () => gmailApi.users.messages.list(
        'me',
        q: query,
        labelIds: labelId != null ? [labelId] : null,
        pageToken: pageToken,
        maxResults: 50, // Small batch for responsiveness
      ),
      logger,
    );

    final messages = response.messages ?? [];
    if (messages.isEmpty) {
      return {'total': 0, 'new': 0, 'skipped': 0};
    }

    final messageIds = messages.map((m) => m.id).whereType<String>().toList();
    final existingEmails = await EmailRepository(appDb).getAllById(messageIds);
    final existingIds = existingEmails.map((e) => e.id).toSet();

    List<Email> emailBatch = [];

    final labelsResponse = await _retryNetworkOp(
      () => gmailApi.users.labels.list('me'),
      logger,
    );
    final labelMap = {
      for (var l in labelsResponse.labels ?? []) l.id!: l.name ?? 'unknown',
    };

    for (var msgRef in messages) {
      try {
        final id = msgRef.id;
        if (id == null) continue;

        // Skip downloading full body and upserting if email is already in local DB
        if (existingIds.contains(id) && !force) {
          skippedCount++;
          continue;
        }

        final m = await _retryNetworkOp(
          () => gmailApi.users.messages.get('me', id, format: 'full'),
          logger,
        );

        DateTime msgDate = DateTime.fromMillisecondsSinceEpoch(
          int.parse(m.internalDate!),
        );

        String? subject = _getHeader(m.payload?.headers, 'subject');
        String? from = _getHeader(m.payload?.headers, 'from');
        String? toRaw = _getHeader(m.payload?.headers, 'to');
        String? ccRaw = _getHeader(m.payload?.headers, 'cc');
        String? messageId = _getHeader(m.payload?.headers, 'message-id');

        String? plainBody = _extractBody(m.payload, 'text/plain');
        String? htmlBody = _extractBody(m.payload, 'text/html');

        // Note: Gmail API doesn't provide a simple "hasAttachments" flag in list view.
        // We check if there are parts with attachmentId or if mimeType is multipart/mixed.
        bool hasAttachments =
            m.payload != null && _checkAttachments(m.payload!);

        final email = Email(
          id: m.id!,
          collectionId: collection.id,
          date: msgDate,
          from: from ?? 'unknown',
          to: toRaw?.split(',').map((e) => e.trim()).toList() ?? [],
          cc: ccRaw?.split(',').map((e) => e.trim()).toList() ?? [],
          subject: subject,
          snippet: m.snippet,
          htmlBody: htmlBody,
          plainBody: plainBody,
          labels: m.labelIds ?? [],
          headers: jsonEncode(m.payload?.headers),
          folderId: labelId,
          messageId: messageId,
          threadId: m.threadId,
          isRead: !(m.labelIds?.contains('UNREAD') ?? false),
          hasAttachments: hasAttachments,
          isDeleted: m.labelIds?.contains('TRASH') ?? false,
        );

        // Double-check precision even with 'after:' query to handle same-second changes
        if (!force && lastScanDate != null) {
          final lastScanSecs = lastScanDate.millisecondsSinceEpoch ~/ 1000;
          final msgSecs = msgDate.millisecondsSinceEpoch ~/ 1000;
          if (msgSecs <= lastScanSecs) {
            skippedCount++;
            continue;
          }
        }

        emailBatch.add(email);
        newCount++;

        if (hasAttachments) {
          final labelName = labelMap[labelId] ?? 'Email';
          final year = msgDate.year.toString();

          final rootPathNormalized = p.normalize(collection.path);
          final relativeYearPath = p.join(labelName, year);
          final absoluteYearPath = p.normalize(
            p.join(rootPathNormalized, relativeYearPath),
          );

          // 1. Ensure folder hierarchy (Collection -> Label -> Year)
          await _ensureFolderHierarchy(
            clientPort: clientPort,
            collection: collection,
            labelName: labelName,
            year: year,
            msgDate: msgDate,
          );

          // 2. Download and send attachments directly into the Year folder
          final attachments = await _downloadAttachments(
            gmailApi,
            collection,
            appDir,
            email.id,
            msgDate,
            [m.payload!],
            targetFolderPath: absoluteYearPath,
            logger: logger,
            htmlBody: htmlBody,
          );
          email.attachments = attachments;

          if (attachments.isNotEmpty) {
            await writeViaMain(clientPort, 'batchFile', attachments);
          }
        }
      } catch (e) {
        logger.w("Failed to fetch/parse message ${msgRef.id}: $e");
      }
    }

    if (emailBatch.isNotEmpty) {
      await writeViaMain(clientPort, 'emailBatch', emailBatch);
      clientPort.send({'type': 'refresh'});
    }

    if (response.nextPageToken != null) {
      final subResults = await _pullEmails(
        gmailApi,
        appDb,
        clientPort,
        collection,
        appDir,
        accessToken,
        labelId: labelId,
        pageToken: response.nextPageToken,
        lastScanDate: lastScanDate,
        force: force,
      );
      total += subResults['total'] ?? 0;
      newCount += subResults['new'] ?? 0;
      skippedCount += subResults['skipped'] ?? 0;
    }

    return {
      'total': total + messages.length,
      'new': newCount,
      'skipped': skippedCount,
    };
  }

  static String? _getHeader(List<MessagePartHeader>? headers, String name) {
    try {
      return headers
          ?.firstWhere((h) => h.name?.toLowerCase() == name.toLowerCase())
          .value;
    } catch (_) {
      return null;
    }
  }

  static String? _extractBody(MessagePart? part, String mimeType) {
    if (part == null) return null;

    if (part.mimeType == mimeType && part.body?.data != null) {
      final rawBytes = EmailDecodingHelper.safeBase64Decode(part.body!.data!);
      if (rawBytes != null && rawBytes.isNotEmpty) {
        final encoding =
            _headerValue(part, 'content-transfer-encoding')?.toLowerCase();
        if (encoding == 'quoted-printable') {
          return EmailDecodingHelper.decodeQuotedPrintable(rawBytes);
        }
        try {
          return utf8.decode(rawBytes, allowMalformed: true);
        } catch (_) {
          return EmailDecodingHelper.decodeQuotedPrintable(rawBytes);
        }
      }
    }

    if (part.parts != null) {
      for (var subPart in part.parts!) {
        final result = _extractBody(subPart, mimeType);
        if (result != null) return result;
      }
    }

    return null;
  }

  /// First value of [name] in a Gmail part's header list, case-insensitively.
  ///
  /// The Gmail API hands back headers as an unparsed name/value list, so
  /// anything enough_mail would have parsed for the IMAP scanners has to be
  /// looked up by hand here.
  static String? _headerValue(MessagePart part, String name) {
    final wanted = name.toLowerCase();
    for (final header in part.headers ?? const <MessagePartHeader>[]) {
      if (header.name?.toLowerCase() == wanted) return header.value;
    }
    return null;
  }

  static bool _checkAttachments(MessagePart part) {
    if (part.body?.attachmentId != null) return true;
    if (part.parts != null) {
      for (var sub in part.parts!) {
        if (_checkAttachments(sub)) return true;
      }
    }
    return false;
  }

  static Future<List<File>> _downloadAttachments(
    GmailApi gmailApi,
    Collection collection,
    String appDir,
    String messageId,
    DateTime msgDate,
    List<MessagePart> parts, {
    String? targetFolderPath,
    AppLogger? logger,
    // Needed to tell an embedded image from a real attachment: the body is
    // what says which parts it references. See `InlineAttachment`.
    String? htmlBody,
  }) async {
    List<File> files = [];
    final sep = io.Platform.pathSeparator;
    // Use the provided year folder path or default to messageId under root
    final effectiveFolderPath =
        targetFolderPath ?? p.normalize('${collection.path}$sep$messageId');

    // Ensure folder exists on disk
    await io.Directory(effectiveFolderPath).create(recursive: true);

    final thumbnailCache = ThumbnailCache(appDir);

    for (var part in parts) {
      if (part.body?.attachmentId != null) {
        try {
          final attachment = await _retryNetworkOp(
            () => gmailApi.users.messages.attachments.get(
              'me',
              messageId,
              part.body!.attachmentId!,
            ),
            logger ?? AppLogger(null),
          );

          final originalFileName = part.filename ?? 'unnamed_attachment';
          // An HTML message drags in every spacer, logo and tracking pixel as
          // a real MIME part. Flagging them here keeps them out of the photo
          // grid and the embedding queue. Gmail exposes the headers as a flat
          // name/value list rather than parsed, hence the lookup.
          final contentId = InlineAttachment.normalizeContentId(
            _headerValue(part, 'content-id'),
          );
          final isInline = InlineAttachment.isInline(
            contentId: contentId,
            fileName: originalFileName,
            htmlBody: htmlBody,
            dispositionInline:
                _headerValue(
                  part,
                  'content-disposition',
                )?.trim().toLowerCase().startsWith('inline') ??
                false,
          );
          // Use prefix to avoid collisions in the flat Year folder
          final fileName = '${messageId}_$originalFileName';
          final file = io.File(p.join(effectiveFolderPath, fileName));
          await file.writeAsBytes(base64Url.decode(attachment.data!));

          final fileId = const Uuid().v5(
            Namespace.url.value,
            'file:email:${collection.id}:$messageId:$fileName',
          );

          // Gmail is the one scanner that keeps the real MIME type on the row;
          // the others store the app's coarse category. ThumbnailGenerator
          // dispatches on the coarse one, so that is what gets handed to it
          // here regardless of what the row ends up recording.
          String? thumbnail;
          if ((part.mimeType ?? '').startsWith('image/')) {
            try {
              thumbnail = await ThumbnailGenerator().generate(
                collection.id,
                fileId,
                file.path,
                FilesConstants.mimeTypeImage,
                thumbnailCache,
              );
            } catch (e) {
              logger?.w(
                'GmailScanner: Failed to generate thumbnail for ${file.path}: $e',
              );
            }
          }

          final f = File(
            id: fileId,
            collectionId: collection.id,
            name: originalFileName,
            path: file.path,
            parent: effectiveFolderPath,
            dateCreated: msgDate,
            dateLastModified: msgDate,
            size: file.lengthSync(),
            contentType: part.mimeType ?? 'application/octet-stream',
            isDeleted: false,
            emailId: messageId,
            thumbnail: thumbnail,
            contentId: contentId,
            isInline: isInline,
          );

          logger?.s(
            "GmailScanner: Sending attachment '${f.name}' to DB (Parent: ${f.parent})",
          );
          files.add(f);
        } catch (e) {
          logger?.w("GmailScanner: Failed to download/save attachment: $e");
        }
      }
      if (part.parts != null) {
        files.addAll(
          await _downloadAttachments(
            gmailApi,
            collection,
            appDir,
            messageId,
            msgDate,
            part.parts!,
            targetFolderPath: effectiveFolderPath,
            logger: logger,
            htmlBody: htmlBody,
          ),
        );
      }
    }
    return files;
  }

  static Future<void> _ensureFolderHierarchy({
    required SendPort clientPort,
    required Collection collection,
    required String labelName,
    required String year,
    required DateTime msgDate,
  }) async {
    final rootPath = collection.path;

    // 1. Label Folder
    final labelPath = p.normalize(p.join(rootPath, labelName));
    await writeViaMain(
      clientPort,
      'folder',
      _createFolderObj(labelPath, rootPath, labelName, collection.id, msgDate),
    );

    // 2. Year Folder
    final yearPath = p.normalize(p.join(labelPath, year));
    await writeViaMain(
      clientPort,
      'folder',
      _createFolderObj(yearPath, labelPath, year, collection.id, msgDate),
    );
  }

  static Folder _createFolderObj(
    String path,
    String parent,
    String name,
    String collectionId,
    DateTime date, {
    String? emailId,
  }) {
    return Folder(
      id: const Uuid().v5(
        Namespace.url.value,
        'folder:email:$collectionId:$path',
      ),
      collectionId: collectionId,
      name: name,
      path: path,
      parent: parent,
      dateCreated: date,
      dateLastModified: date,
      emailId: emailId,
    );
  }

  static EmailFolder mapLabelToFolder(Label label, String collectionId) {
    return EmailFolder(
      id: label.id!,
      collectionId: collectionId,
      name: label.name!,
      type: label.type == 'system' ? 'system' : 'user',
      messagesTotal: label.messagesTotal,
      messagesUnread: label.messagesUnread,
    );
  }

  // Thin delegate to the shared helper (scan_isolate_support.dart) so call
  // sites are unchanged; the retry logic lives in one place now.
  static Future<T> _retryNetworkOp<T>(
    Future<T> Function() operation,
    AppLogger logger,
  ) => retryNetworkOp(operation, logger: logger);
}
