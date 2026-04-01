import 'dart:isolate';
import 'dart:convert';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/models/tables/file.dart' as db_file;
import 'package:mydatatools/models/tables/folder.dart' as db_folder;
import 'package:mydatatools/modules/email/services/get_emails_service.dart';
import 'package:mydatatools/modules/files/files_constants.dart';
import 'package:mydatatools/modules/files/services/scanners/scanner_path_helper.dart';
import 'dart:io' as io;
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:mydatatools/modules/files/services/utilities/thumbnail_generator.dart';
import 'package:uuid/uuid.dart';

/// [OutlookScannerIsolate] is the client-side manager for the Outlook scanning
/// background isolate. It handles spawning the worker, parameter propagation,
/// and bidirectional communication during the IMAP sync process.
///
/// Synchronization Rules:
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
class OutlookScannerIsolate {
  final RootIsolateToken? token;
  final SendPort? dbWriterPort;
  final String appDir;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  OutlookScannerIsolate({this.token, this.dbWriterPort, required this.appDir});

  /// Spawns the Outlook background worker isolate.
  ///
  /// [collection] The collection to synchronize.
  /// [folderId] Mode selector:
  ///   - If NULL: **Full Sync**. Synchronizes all folders.
  ///   - If NOT NULL: **Targeted Scan**. Focuses ONLY on the specified folder ID
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

    if (dbWriterPort == null) {
      throw Exception("dbWriterPort is required for OutlookScannerIsolate");
    }

    ReceivePort receivePort = ReceivePort("OutlookScannerIsolateClient");

    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'port': receivePort.sendPort,
      'dbWriterPort': dbWriterPort,
      'collection': collection,
      'folderId': folderId,
      'lastScanDate': collection.lastScanDate?.toIso8601String(),
      'force': force,
      'appDir': appDir,
    };

    _isolate = await spawnIsolate(OutlookScannerIsolateWorker.worker, args);

    bool isIsolateDone = false;
    bool isCleanupInProgress = false;

    void checkDone() {
      if (isIsolateDone && !isCleanupInProgress) {
        if (statusPort != null) {
          statusPort.send({'status': 'done'});
        }
      }
    }

    receivePort.listen((message) {
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
        } else if (message['type'] == 'cleanup_uids') {
          final db = DatabaseManager.instance.appDatabase;
          if (db != null) {
            isCleanupInProgress = true;
            final repo = EmailRepository(db);
            repo
                .cleanupDeletedOutlook(
                  collection,
                  message['folder'],
                  (message['uids'] as List).cast<int>(),
                )
                .then((_) {
                  isCleanupInProgress = false;
                  checkDone();
                });
          }
        }

        if (message['status'] == 'done') {
          isIsolateDone = true;
          checkDone();
          return; // Don't send double done
        }
      }

      // Relay all other messages to statusPort
      if (statusPort != null) statusPort.send(message);
    });

    if (statusPort != null) {
      statusPort.send({'status': 'scanning'});
    }
  }

  Future<void> moveToTrash(
    Collection collection, {
    String? folderId,
    required List<int> uids,
    SendPort? statusPort,
  }) async {
    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'dbWriterPort': dbWriterPort,
      'collection': collection,
      'folderId': folderId,
      'uids': uids,
      'type': 'move_to_trash',
      'appDir': appDir,
    };

    // We use a fresh isolate for the move operation to avoid blocking or being blocked by long-running scans
    await Isolate.spawn(OutlookScannerIsolateWorker.worker, args);
    if (statusPort != null) {
      statusPort.send("Remote delete request sent for ${uids.length} messages");
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

class OutlookScannerIsolateWorker {
  static Future<void> worker(Map<String, dynamic> args) async {
    final RootIsolateToken? token = args['token'];
    final SendPort? clientPort = args['port'];
    final SendPort dbWriterPort = args['dbWriterPort'];
    final Collection collection = args['collection'];
    final String? folderId = args['folderId'];
    final String type = args['type'] ?? 'sync';
    final String? lastScanDateStr = args['lastScanDate'];
    final DateTime? lastScanDate =
        lastScanDateStr != null ? DateTime.tryParse(lastScanDateStr) : null;
    final bool force = args['force'] ?? false;

    final List<int>? uidsToMove =
        args['uids'] != null ? (args['uids'] as List).cast<int>() : null;

    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);
    final emailAddress = collection.name;
    final accessToken = collection.accessToken!;

    final client = ImapClient(isLogEnabled: true);
    try {
      logger.i("DEBUG: Outlook Isolate - Connecting for $type...");
      logger.i("DEBUG: Outlook Isolate - Target Email: $emailAddress");
      // Use imap-mail.outlook.com for better personal account support
      await client.connectToServer('imap-mail.outlook.com', 993, isSecure: true);
      
      // DIAGNOSTICS: Log token audience and scopes
      try {
        final parts = accessToken.split('.');
        if (parts.length == 3) {
          final payload = parts[1];
          final normalized = base64Url.normalize(payload);
          final decoded = utf8.decode(base64Url.decode(normalized));
          final claims = jsonDecode(decoded) as Map<String, dynamic>;
          final aud = claims['aud'];
          final scp = claims['scp'] ?? claims['roles'];
          final tid = claims['tid'];
          logger.i("DEBUG: Token Diagnostics - Audience: $aud");
          logger.i("DEBUG: Token Diagnostics - Scopes: $scp");
          logger.i("DEBUG: Token Diagnostics - Tenant ID: $tid");
          
          if (aud != "https://outlook.office.com" && aud != "https://graph.microsoft.com") {
            logger.w("WARNING: Access token audience is '$aud', expected 'https://outlook.office.com'.");
          }
        } else {
          logger.i("DEBUG: Token Diagnostics - Access token is opaque.");
        }
      } catch (e) {
        logger.i("DEBUG: Token Diagnostics - Failed to decode token: $e");
      }

      logger.i("Authenticating with Outlook IMAP as: $emailAddress (Host: imap-mail.outlook.com)");
      try {
        await client.authenticateWithOAuth2(emailAddress, accessToken);
      } catch (e) {
        if (e.toString().contains('AUTHENTICATE failed')) {
           logger.e("IMAP AUTHENTICATE failed. This usually means the token was rejected by Microsoft.");
           // If there was a challenge (+ <base64>), enough_mail might not expose it easily, 
           // but we've enabled protocol logging so check the console for 'S: + ...'
        }
        rethrow;
      }

      if (type == 'move_to_trash' &&
          uidsToMove != null &&
          uidsToMove.isNotEmpty) {
        final mailboxes = await client.listMailboxes();
        // Use flag-based discovery first, then fall back to common names
        final trashMailbox =
            mailboxes.where((m) => m.isTrash).firstOrNull ??
            mailboxes
                .where(
                  (m) =>
                      m.name.toLowerCase() == 'trash' ||
                      m.name.toLowerCase() == 'archive',
                )
                .firstOrNull;

        final trashPath = trashMailbox?.name ?? 'Trash';
        final targetFolder = folderId ?? 'INBOX';

        logger.s(
          "Moving ${uidsToMove.length} messages to $trashPath from $targetFolder...",
        );
        await client.selectMailboxByPath(targetFolder);

        final sequence = MessageSequence();
        for (final uid in uidsToMove) {
          sequence.add(uid);
        }
        try {
          await client.uidMove(sequence, targetMailboxPath: trashPath);
          logger.s("Cleanup: remote move to $trashPath complete.");
        } catch (e) {
          logger.e(
            "Error during IMAP MOVE: $e. Attempting Copy/Delete fallback.",
          );
          // Fallback: Copy -> Delete -> Expunge
          try {
            await client.uidCopy(sequence, targetMailboxPath: trashPath);
            await client.uidStore(sequence, [
              MessageFlags.deleted,
            ], action: StoreAction.add);
            await client.uidExpunge(sequence);
            logger.s("Cleanup: move to Trash completed via fallback.");
          } catch (e2) {
            logger.e("Fallback Copy/Delete failed: $e2");
          }
        }

        await client.logout();
        return;
      }

      final scanStartTime = DateTime.now();
      int totalFound = 0;
      int newEmails = 0;
      int skipped = 0;

      // 1. Sync Folders
      logger.s("Syncing Outlook folders...");
      final mailboxes = await client.listMailboxes();
      for (final mailbox in mailboxes) {
        final folder = EmailFolder(
          id: mailbox.name,
          collectionId: collection.id,
          name: mailbox.name,
          type: getFolderType(mailbox.name),
        );
        dbWriterPort.send({'type': 'folder', 'folder': folder});
      }

      // 2. Sync Emails
      final targetFolder = folderId ?? 'INBOX';
      logger.s("Syncing folder: $targetFolder");
      await client.selectMailboxByPath(targetFolder);

      // Fetch UIDs for the folder
      List<int> allUids = [];
      try {
        // Build search criteria
        String searchCriteria = 'ALL';
        if (!force && lastScanDate != null) {
          // IMAP SINCE query uses day-level precision (RFC 3501)
          // We subtract 1 day to be safe around timezones/boundaries
          final sinceDate = lastScanDate.subtract(const Duration(days: 1));
          final monthNames = [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
          ];
          final dateStr =
              "${sinceDate.day}-${monthNames[sinceDate.month - 1]}-${sinceDate.year}";
          searchCriteria = 'SINCE $dateStr';
          logger.i("Outlook: Performing incremental sync SINCE $dateStr");
        }

        final searchResult = await client.uidSearchMessages(
          searchCriteria: searchCriteria,
        );
        allUids = searchResult.matchingSequence?.toList() ?? [];
        totalFound = allUids.length;

        if (searchCriteria == 'ALL') {
          clientPort?.send({
            'type': 'cleanup_uids',
            'folder': targetFolder,
            'uids': allUids,
          });
        }
      } catch (err) {
        logger.e("Failed to fetch UIDs for folder: $err");
      }

      if (allUids.isEmpty) {
        logger.s("No new messages found in $targetFolder.");
      } else {
        const int batchSize = 50;
        final reversedUids = allUids.reversed.toList();
        logger.s(
          "Processing ${reversedUids.length} messages in $targetFolder...",
        );

        for (int i = 0; i < reversedUids.length; i += batchSize) {
          final end =
              (i + batchSize < reversedUids.length)
                  ? i + batchSize
                  : reversedUids.length;
          final batchUids = reversedUids.sublist(i, end);

          logger.s(
            "Fetching batch ${(i ~/ batchSize) + 1} (${batchUids.length} messages)...",
          );

          final sequence = MessageSequence();
          for (final uid in batchUids) {
            sequence.add(uid);
          }

          try {
            final fetchResult = await client.uidFetchMessages(
              sequence,
              'BODY.PEEK[]',
            );
            logger.s(
              "Fetched ${fetchResult.messages.length} messages in batch.",
            );

            List<Email> emailBatch = [];
            for (final message in fetchResult.messages) {
              final msgDate = message.decodeDate() ?? DateTime.now();

              // Refine incremental check with second-level precision
              if (!force && lastScanDate != null) {
                // Truncate both to seconds for reliable comparison
                final lastScanSecs = lastScanDate.millisecondsSinceEpoch ~/ 1000;
                final msgSecs = msgDate.millisecondsSinceEpoch ~/ 1000;
                
                if (msgSecs <= lastScanSecs) {
                  skipped++;
                  continue;
                }
              }

              final emailObj = await _parseAndProcessMessage(
                message: message,
                collection: collection,
                targetFolder: targetFolder,
                appDir: args['appDir'] as String,
                dbWriterPort: dbWriterPort,
                logger: logger,
              );
              emailBatch.add(emailObj);
              newEmails++;
            }

            if (emailBatch.isNotEmpty) {
              dbWriterPort.send({'type': 'batch_email', 'emails': emailBatch});
              clientPort?.send({'type': 'refresh'});
            }
          } catch (e) {
            logger.e("Failed to fetch batch starting at $i: $e");
          }
        }
      }

      logger.i(
        "Outlook sync complete: $totalFound found, $newEmails new, $skipped skipped.",
      );

      // Update lastScanDate in the DB
      dbWriterPort.send({
        'type': 'update_collection_status',
        'id': collection.id,
        'status': 'ready',
        'lastScan': scanStartTime.toIso8601String(),
      });

      clientPort?.send({'type': 'refresh', 'status': 'done'});
    } catch (e, stack) {
      logger.e("Error in Outlook Isolate: $e", error: e, stackTrace: stack);
    } finally {
      if (client.isLoggedIn) {
        try {
          await client.logout();
        } catch (_) {}
      }
      Isolate.exit(clientPort, {'status': 'done'});
    }
  }

  /// Returns all MIME parts that have a filename (i.e. are attachments or
  /// named inline parts). Uses enough_mail's built-in [allPartsFlat] so we
  /// correctly traverse the whole MIME tree without reimplementing it.
  static List<MimePart> _collectAttachmentParts(MimeMessage message) {
    return message.allPartsFlat
        .where((part) => part.decodeFileName() != null)
        .toList();
  }

  static Future<List<db_file.File>> _downloadAttachments({
    required Collection collection,
    required String messageId,
    required DateTime msgDate,
    required List<MimePart> parts,
    required String targetFolderPath, // absolute path on disk
    required String
    extractionRoot, // absolute collection root → for relative-path computation
    required SendPort dbWriterPort,
    required AppLogger logger,
  }) async {
    List<db_file.File> files = [];
    await io.Directory(targetFolderPath).create(recursive: true);

    // SMTP Message-IDs often contain '<', '>', '@', '/' and other chars that
    // are illegal in file-system paths. Strip everything unsafe.
    final safeMessageId = messageId
        .replaceAll(RegExp(r'[<>:/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');

    for (final part in parts) {
      final rawFileName = part.decodeFileName();
      if (rawFileName == null) continue;
      // Sanitize filename to prevent path traversal
      final fileName = p.basename(rawFileName).replaceAll('..', '');

      Uint8List? content;
      try {
        content = part.decodeContentBinary();
      } catch (e) {
        // Malformed base64 / encoding errors — skip this attachment only.
        logger.w(
          'OutlookScanner: Could not decode attachment $fileName (encoding error): $e',
        );
        continue;
      }

      try {
        if (content != null && content.isNotEmpty) {
          final file = io.File(
            p.join(targetFolderPath, '${safeMessageId}_$fileName'),
          );
          await file.writeAsBytes(content);

          // Store relative paths so FilePathResolver + GetFileAndFoldersService
          // can resolve them back to absolute using collection.localCopyPath.
          // Generate thumbnail if it's an image
          String? thumbnail;
          if (mapMimeType(part.mediaType.text) ==
              FilesConstants.mimeTypeImage) {
            try {
              thumbnail = await ThumbnailGenerator().pathImageToBase64(
                file.path,
                FilesConstants.mimeTypeImage,
              );
            } catch (e) {
              logger.w(
                'OutlookScanner: Failed to generate thumbnail for ${file.path}: $e',
              );
            }
          }

          String? relPath;
          String? relParent;
          try {
            relPath = ScannerPathHelper.relativePath(file.path, extractionRoot);
            relParent = ScannerPathHelper.relativeParent(
              file.path,
              extractionRoot,
            );
          } catch (e) {
            logger.w(
              'OutlookScanner: Failed to compute relative path for ${file.path}: $e',
            );
          }

          final f = db_file.File(
            id: const Uuid().v5(
              Namespace.url.value,
              'file:email:${collection.id}:$messageId:$fileName',
            ),
            collectionId: collection.id,
            name: fileName,
            path: relPath ?? file.path,
            parent: relParent ?? '',
            dateCreated: msgDate,
            dateLastModified: msgDate,
            size: file.lengthSync(),
            contentType: mapMimeType(part.mediaType.text),
            isDeleted: false,
            emailId: messageId,
            thumbnail: thumbnail,
          );
          files.add(f);
        }
      } catch (e) {
        logger.w('OutlookScanner: Failed to save attachment $fileName: $e');
      }
    }
    return files;
  }

  static Future<void> _ensureFolderHierarchy({
    required SendPort dbWriterPort,
    required Collection collection,
    required String extractionRoot,
    required String labelName,
    required String year,
    required DateTime msgDate,
  }) async {
    // Absolute paths are used only for the folder ID (stable UUID seed);
    // path/parent stored in the DB are relative to extractionRoot.
    final labelAbsPath = p.normalize(p.join(extractionRoot, labelName));
    final yearAbsPath = p.normalize(p.join(labelAbsPath, year));

    dbWriterPort.send({
      'type': 'folder',
      'folder': _createFolderObj(
        absPath: labelAbsPath,
        extractionRoot: extractionRoot,
        name: labelName,
        collectionId: collection.id,
        date: msgDate,
      ),
    });
    dbWriterPort.send({
      'type': 'folder',
      'folder': _createFolderObj(
        absPath: yearAbsPath,
        extractionRoot: extractionRoot,
        name: year,
        collectionId: collection.id,
        date: msgDate,
      ),
    });
  }

  /// Builds a [Folder] with relative path/parent so it matches the queries
  /// in [GetFileAndFoldersService] that filter on the relative parent column.
  static db_folder.Folder _createFolderObj({
    required String absPath,
    required String extractionRoot,
    required String name,
    required String collectionId,
    required DateTime date,
  }) {
    final relPath = ScannerPathHelper.relativePath(
      absPath,
      extractionRoot,
      isFolder: true,
    );
    final relParent = ScannerPathHelper.relativeParent(absPath, extractionRoot);
    return db_folder.Folder(
      id: const Uuid().v5(
        Namespace.url.value,
        'folder:email:$collectionId:$absPath',
      ),
      collectionId: collectionId,
      name: name,
      path: relPath,
      parent: relParent,
      dateCreated: date,
      dateLastModified: date,
    );
  }

  static String getFolderType(String name) {
    final n = name.toUpperCase();
    if (n == 'INBOX' ||
        n == 'SENT' ||
        n == 'TRASH' ||
        n == 'SPAM' ||
        n == 'DRAFTS') {
      return 'system';
    }
    return 'user';
  }

  static Future<Email> _parseAndProcessMessage({
    required MimeMessage message,
    required Collection collection,
    required String targetFolder,
    required String appDir,
    required SendPort dbWriterPort,
    required AppLogger logger,
  }) async {
    final messageId = message.getHeaderValue('Message-ID');
    int? uid;
    try {
      uid = (message as dynamic).uid;
    } catch (_) {}

    String emailId =
        messageId ??
        const Uuid().v5(
          Namespace.url.value,
          'email:outlook:${collection.id}:$targetFolder:${uid ?? const Uuid().v4()}',
        );

    final plainBody = message.decodeTextPlainPart();
    final htmlBody = message.decodeTextHtmlPart();
    final snippet =
        plainBody != null
            ? (plainBody.length > 200 ? plainBody.substring(0, 200) : plainBody)
            : '';

    final hasAttachments = message.hasAttachments();
    final msgDate = message.decodeDate() ?? DateTime.now();

    final emailObj = Email(
      id: emailId,
      uid: uid,
      collectionId: collection.id,
      date: msgDate,
      from: message.from?.first.toString() ?? 'unknown',
      to: message.to?.map((e) => e.toString()).toList() ?? [],
      cc: message.cc?.map((e) => e.toString()).toList() ?? [],
      subject: message.decodeSubject() ?? '(no subject)',
      snippet: snippet,
      plainBody: plainBody,
      htmlBody: htmlBody,
      folderId: targetFolder,
      messageId: messageId,
      isRead: false,
      hasAttachments: hasAttachments,
      isDeleted: false,
    );

    if (collection.downloadLocalCopy) {
      final labelName = targetFolder;
      final year = msgDate.year.toString();
      // Use the app-managed extraction root (not collection.path which is an
      // email address for Outlook accounts) so paths are absolute on disk.
      final extractionRoot = p.normalize(
        p.join(appDir, 'files', 'email', collection.id),
      );
      final absoluteYearPath = p.normalize(
        p.join(extractionRoot, labelName, year),
      );

      await _ensureFolderHierarchy(
        dbWriterPort: dbWriterPort,
        collection: collection,
        extractionRoot: extractionRoot,
        labelName: labelName,
        year: year,
        msgDate: msgDate,
      );

      final attachmentParts = _collectAttachmentParts(message);
      final attachments = await _downloadAttachments(
        collection: collection,
        messageId: emailId,
        msgDate: msgDate,
        parts: attachmentParts,
        targetFolderPath: absoluteYearPath,
        extractionRoot:
            extractionRoot, // ← pass root for relative-path computation
        dbWriterPort: dbWriterPort,
        logger: logger,
      );
      emailObj.attachments = attachments;
      for (var file in attachments) {
        dbWriterPort.send({'type': 'file', 'file': file});
      }
    }
    return emailObj;
  }

  /// Maps a standard MIME type to the internal [FilesConstants] value.
  static String mapMimeType(String mimeType) {
    if (mimeType.startsWith('image/')) return FilesConstants.mimeTypeImage;
    if (mimeType.startsWith('video/')) return FilesConstants.mimeTypeMovie;
    if (mimeType.startsWith('audio/')) return FilesConstants.mimeTypeMusic;
    if (mimeType == 'application/pdf') return FilesConstants.mimeTypePdf;
    return FilesConstants.mimeTypeUnKnown;
  }
}
