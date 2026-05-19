import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:googleapis/gmail/v1.dart';
import 'package:path/path.dart' as p;
import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/modules/email/services/email_folder_upsert_service.dart';
import 'package:mydatatools/modules/email/services/email_upsert_service.dart';
import 'package:mydatatools/modules/email/services/get_emails_service.dart';
import 'package:mydatatools/modules/files/services/file_upsert_service.dart';
import 'package:mydatatools/modules/files/services/folder_upsert_service.dart';
import 'package:mydatatools/file_sources/google_drive/google_auth_service.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
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
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  GmailScannerIsolate({this.token, required this.appDir});

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
    };

    _isolate = await spawnIsolate(GmailScannerIsolateWorker.worker, args);

    receivePort.listen((message) {
      // Forward status messages if requested
      if (statusPort != null) {
        statusPort.send(message);
      }

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
    final RootIsolateToken? token = args['token'];
    final SendPort clientPort = args['port'];
    final Collection collection = args['collection'];
    final String? folderId = args['folderId'];
    final String? lastScanDateStr = args['lastScanDate'];
    final DateTime? lastScanDate =
        lastScanDateStr != null ? DateTime.tryParse(lastScanDateStr) : null;
    final bool force = args['force'] ?? false;
    final String appDir = args['appDir'];

    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);

    // Validate tokens exist before attempting refresh or API calls.
    // Dart flow-analysis doesn't recognise Isolate.exit() as a terminator,
    // so we use local non-nullable bindings instead of the ! operator.
    final accessTokenRaw = collection.accessToken;
    final refreshTokenRaw = collection.refreshToken;
    if (accessTokenRaw == null || refreshTokenRaw == null) {
      logger.e('GmailScannerIsolate: no tokens for "${collection.name}" — aborting scan');
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

    final appDb = await AppDatabase.create(null, appDir, AppConstants.dbName);

    final authHttpClient = AuthenticatedHttpClient.bearer(accessToken);
    final GmailApi gmailApi = GmailApi(authHttpClient);

    try {
      // 1. Sync Labels (Folders)
      logger.s("Syncing Gmail labels...");
      final labelsResponse = await gmailApi.users.labels.list('me');
      final labels = labelsResponse.labels ?? [];

      for (var label in labels) {
        final folder = mapLabelToFolder(label, collection.id);
        await EmailFolderUpsertService.instance.invoke(
          EmailFolderUpsertServiceCommand(folder, appDb),
        );
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

      // Update lastScanDate in the DB
      final collectionRepo = CollectionRepository(appDb);
      final col = await collectionRepo.collectionById(collection.id);
      if (col != null) {
        col.scanStatus = 'ready';
        col.lastScanDate = scanStartTime;
        await collectionRepo.updateCollection(col);
      }

      clientPort.send({'type': 'refresh', 'status': 'done'});
    } catch (e, stack) {
      logger.e("Error in Gmail Isolate: $e", error: e, stackTrace: stack);
    } finally {
      Isolate.exit(clientPort, {'status': 'done'});
    }
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

    final response = await gmailApi.users.messages.list(
      'me',
      q: query,
      labelIds: labelId != null ? [labelId] : null,
      pageToken: pageToken,
      maxResults: 50, // Small batch for responsiveness
    );

    final messages = response.messages ?? [];
    if (messages.isEmpty) {
      return {
        'total': 0,
        'new': 0,
        'skipped': 0,
      };
    }

    List<Email> emailBatch = [];

    final labelsResponse = await gmailApi.users.labels.list('me');
    final labelMap = {
      for (var l in labelsResponse.labels ?? []) l.id!: l.name ?? 'unknown',
    };

    for (var msgRef in messages) {
      try {
        final m = await gmailApi.users.messages.get(
          'me',
          msgRef.id!,
          format: 'full',
        );

        DateTime msgDate = DateTime.fromMillisecondsSinceEpoch(
          int.parse(m.internalDate!),
        );

        String? subject = _getHeader(m.payload?.headers, 'subject');
        String? from = _getHeader(m.payload?.headers, 'from');
        String? toRaw = _getHeader(m.payload?.headers, 'to');
        String? ccRaw = _getHeader(m.payload?.headers, 'cc');
        String? messageId = _getHeader(m.payload?.headers, 'message-id');

        String? plainBody = _parseBodyParts(
          m.payload?.parts ?? [],
          'text/plain',
        );
        String? htmlBody = _parseBodyParts(m.payload?.parts ?? [], 'text/html');

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

          logger.s(
            "GmailScanner: Processing email ${email.id} with attachments. Target: $absoluteYearPath",
          );

          // 1. Ensure folder hierarchy (Collection -> Label -> Year)
          await _ensureFolderHierarchy(
            appDb: appDb,
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
          );
          email.attachments = attachments;

          for (var file in attachments) {
            await FileUpsertService.instance.invoke(
              FileUpsertServiceCommand(file, appDb),
            );
          }
        }
      } catch (e) {
        logger.w("Failed to fetch/parse message ${msgRef.id}: $e");
      }
    }

    if (emailBatch.isNotEmpty) {
      await EmailUpsertService.instance.invoke(
        EmailUpsertServiceCommand(emailBatch, appDb),
      );
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

  static String? _parseBodyParts(List<MessagePart> parts, String mimeType) {
    for (var part in parts) {
      if (part.mimeType == mimeType && part.body?.data != null) {
        return utf8.decode(base64Url.decode(part.body!.data!));
      }
      if (part.parts != null) {
        final result = _parseBodyParts(part.parts!, mimeType);
        if (result != null) return result;
      }
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
  }) async {
    List<File> files = [];
    final sep = io.Platform.pathSeparator;
    // Use the provided year folder path or default to messageId under root
    final effectiveFolderPath =
        targetFolderPath ?? p.normalize('${collection.path}$sep$messageId');

    // Ensure folder exists on disk
    await io.Directory(effectiveFolderPath).create(recursive: true);

    for (var part in parts) {
      if (part.body?.attachmentId != null) {
        try {
          final attachment = await gmailApi.users.messages.attachments.get(
            'me',
            messageId,
            part.body!.attachmentId!,
          );

          final originalFileName = part.filename ?? 'unnamed_attachment';
          // Use prefix to avoid collisions in the flat Year folder
          final fileName = '${messageId}_$originalFileName';
          final file = io.File(p.join(effectiveFolderPath, fileName));
          await file.writeAsBytes(base64Url.decode(attachment.data!));

          final f = File(
            id: const Uuid().v5(
              Namespace.url.value,
              'file:email:${collection.id}:$messageId:$fileName',
            ),
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
          ),
        );
      }
    }
    return files;
  }

  static Future<void> _ensureFolderHierarchy({
    required AppDatabase appDb,
    required Collection collection,
    required String labelName,
    required String year,
    required DateTime msgDate,
  }) async {
    final rootPath = collection.path;

    // 1. Label Folder
    final labelPath = p.normalize(p.join(rootPath, labelName));
    await FolderUpsertService.instance.invoke(
      FolderUpsertServiceCommand(
        _createFolderObj(labelPath, rootPath, labelName, collection.id, msgDate),
        appDb,
      ),
    );

    // 2. Year Folder
    final yearPath = p.normalize(p.join(labelPath, year));
    await FolderUpsertService.instance.invoke(
      FolderUpsertServiceCommand(
        _createFolderObj(yearPath, labelPath, year, collection.id, msgDate),
        appDb,
      ),
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
}
