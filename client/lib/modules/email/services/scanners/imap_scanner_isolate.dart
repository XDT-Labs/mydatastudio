import 'dart:isolate';
import 'dart:convert';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/scanners/scan_isolate_support.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/services/vault_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/models/tables/file.dart' as db_file;
import 'package:mydatastudio/models/tables/folder.dart' as db_folder;
import 'package:mydatastudio/modules/email/services/email_decoding_helper.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/email/services/get_emails_service.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/folder_role_mapper.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_connection_config.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/email/services/inline_attachment.dart';
import 'package:mydatastudio/modules/files/services/scanners/scanner_path_helper.dart';
import 'dart:io' as io;

import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_generator.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/scan_write_relay.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';
import 'package:uuid/uuid.dart';

/// [ImapScannerIsolate] is the client-side manager for the IMAP scanning
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
class ImapScannerIsolate {
  final RootIsolateToken? token;
  final String appDir;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  ImapScannerIsolate({this.token, required this.appDir, required this.dbDir});

  final String dbDir;

  /// Spawns the IMAP background worker isolate.
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

    ReceivePort receivePort = ReceivePort("ImapScannerIsolateClient");

    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'port': receivePort.sendPort,
      'collection': collection,
      'folderId': folderId,
      'lastScanDate': collection.lastScanDate?.toIso8601String(),
      'force': force,
      'appDir': appDir,
      'dbDir': dbDir,
      // DEK so the worker can decrypt/encrypt collection tokens (AUDIT M2 ph4).
      'vaultDek': VaultManager.instance.dek,
    };

    _isolate = await spawnIsolate(ImapScannerIsolateWorker.worker, args);

    bool isIsolateDone = false;
    bool isCleanupInProgress = false;

    void checkDone() {
      if (isIsolateDone && !isCleanupInProgress) {
        if (statusPort != null) {
          statusPort.send({'status': 'done'});
        }
      }
    }

    final writeQueue = SequentialWriteQueue();

    receivePort.listen((message) {
      if (relayIsolateLog(logger, message, '[ImapScan]')) return;
      // Queued rather than handled inline — see gmail_scanner_isolate.dart.
      if (tryHandleScanWrite(message, writeQueue)) return;
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
          isCleanupInProgress = true;
          final db = DatabaseManager.instance.database!;
          EmailRepository(db)
              .cleanupDeletedImap(
                collection,
                message['folder'] as String,
                (message['uids'] as List).cast<int>(),
              )
              .catchError((Object err) {
                // `deleteEmails` throws now, and this future is unawaited: a
                // failed cleanup must not leave `isCleanupInProgress` stuck
                // true, which would hold the scan open forever.
                logger.e("IMAP cleanup failed: $err");
              })
              .whenComplete(() {
                isCleanupInProgress = false;
                checkDone();
              });
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
      'collection': collection,
      'folderId': folderId,
      'uids': uids,
      'type': 'move_to_trash',
      'appDir': appDir,
      'dbDir': dbDir,
      'vaultDek': VaultManager.instance.dek,
    };

    // We use a fresh isolate for the move operation to avoid blocking or being blocked by long-running scans
    await Isolate.spawn(ImapScannerIsolateWorker.worker, args);
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

/// Row counts from syncing one folder.
typedef FolderSyncCounts = ({int found, int added, int skipped});

class ImapScannerIsolateWorker {
  /// Isolate entry point. All the work is in [execute]; this only adds the
  /// zone guard and guarantees the client is told when the worker is done.
  static Future<void> worker(Map<String, dynamic> args) async {
    runInScanIsolateZone(() async {
      final SendPort? clientPort = args['port'];
      try {
        await execute(args);
      } finally {
        Isolate.exit(clientPort, {'status': 'done'});
      }
    });
  }

  /// Runs one sync (or `move_to_trash`) job. Separate from [worker] so tests
  /// can drive it in-process (the entry point ends with `Isolate.exit`).
  /// Never throws: failures are logged, as the old Yahoo/Outlook workers did.
  static Future<void> execute(Map<String, dynamic> args) async {
    final RootIsolateToken? token = args['token'];
    final SendPort? clientPort = args['port'];
    final Collection collection = args['collection'];
    final String? folderId = args['folderId'];
    final String type = args['type'] ?? 'sync';
    final String? lastScanDateStr = args['lastScanDate'];
    final DateTime? lastScanDate =
        lastScanDateStr != null ? DateTime.tryParse(lastScanDateStr) : null;
    final bool force = args['force'] ?? false;
    final String appDir = args['appDir'] as String;
    final String dbDir = args['dbDir'] as String? ?? appDir;

    final List<int>? uidsToMove =
        args['uids'] != null ? (args['uids'] as List).cast<int>() : null;

    // Init platform channels + install the credential vault (AUDIT M2 phase 4).
    bootstrapScanIsolate(token, args['vaultDek'] as Uint8List?);

    final AppLogger logger = AppLogger(clientPort);

    final ImapConnectionConfig config;
    try {
      config = ImapConnectionConfig.fromCollection(collection);
    } on ImapConfigException catch (e) {
      logger.e('IMAP scan aborted for ${collection.name}: ${e.message}');
      if (clientPort != null) {
        try {
          await writeViaMain(clientPort, 'collectionStatus', {
            'collectionId': collection.id,
            'scanStatus': 'error',
            // null: leave last_scan_date as it is.
            'lastScanDate': null,
          });
        } catch (err) {
          logger.e('Could not record scan error status: $err');
        }
      }
      return;
    }

    final client = ImapClient(isLogEnabled: false);
    try {
      await connectAndAuthenticate(client, config, logger);

      if (type == 'move_to_trash' &&
          uidsToMove != null &&
          uidsToMove.isNotEmpty) {
        await _moveToTrash(
          client,
          folderId: folderId,
          uids: uidsToMove,
          logger: logger,
        );
        await client.logout();
        return;
      }

      // move_to_trash spawns this worker without a 'port' arg, so
      // clientPort is null for that call. It always returns above before
      // reaching here — but only when uidsToMove is non-empty; guard
      // explicitly rather than relying on that to hold and crashing on the
      // first clientPort! below if it doesn't.
      if (clientPort == null) {
        logger.e(
          'ImapScannerIsolate: no clientPort for a sync-path run — '
          'aborting rather than crashing on a null write relay',
        );
        await client.logout();
        return;
      }

      final appDb = await AppDatabase.create(null, dbDir, AppConstants.dbName);

      final scanStartTime = DateTime.now();

      // 1. Sync Folders
      logger.s("Syncing ${config.provider.displayName} folders...");
      await _syncFolderList(client, config, collection, clientPort);

      // 2. Sync Emails
      final targetFolder = folderId ?? 'INBOX';
      final counts = await _syncFolder(
        client: client,
        collection: collection,
        providerId: config.provider.id,
        targetFolder: targetFolder,
        force: force,
        lastScanDate: lastScanDate,
        appDir: appDir,
        clientPort: clientPort,
        logger: logger,
      );

      logger.i(
        "IMAP sync complete: ${counts.found} found, ${counts.added} new, "
        "${counts.skipped} skipped.",
      );

      // Update lastScanDate in the DB. The read stays on this isolate's own
      // connection; only the write goes back to main.
      final collectionRepo = CollectionRepository(appDb);
      final col = await collectionRepo.collectionById(collection.id);
      if (col != null) {
        await writeViaMain(clientPort, 'collectionStatus', {
          'collectionId': col.id,
          'scanStatus': 'ready',
          'lastScanDate': scanStartTime,
        });
      }

      clientPort.send({'type': 'refresh', 'status': 'done'});
    } catch (e, stack) {
      logger.e("Error in IMAP Isolate: $e", error: e, stackTrace: stack);
    } finally {
      // A dropped socket after a long sync makes logout throw; letting that
      // escape would skip the caller's exit, so the client never gets 'done'.
      if (client.isLoggedIn) {
        try {
          await client.logout();
        } catch (_) {}
      }
    }
  }

  /// Opens the connection with the provider's host/port/security, then
  /// authenticates.
  static Future<void> connectAndAuthenticate(
    ImapClient client,
    ImapConnectionConfig config,
    AppLogger logger,
  ) async {
    await client.connectToServer(
      config.host,
      config.port,
      isSecure: config.security == ImapSecurity.ssl,
    );
    if (config.security == ImapSecurity.startTls) {
      await client.startTls();
    }
    await authenticate(client, config, logger);
  }

  /// oauth2 -> XOAUTH2; appPassword/password -> LOGIN.
  static Future<void> authenticate(
    ImapClient client,
    ImapConnectionConfig config,
    AppLogger logger,
  ) async {
    switch (config.authType) {
      case EmailAuthType.oauth2:
        if (config.provider.id == 'outlook') {
          _logOutlookTokenDiagnostics(config.secret, logger);
        }
        logger.i(
          "Authenticating with ${config.provider.displayName} IMAP as: "
          "${config.username} (Host: ${config.host})",
        );
        try {
          await client.authenticateWithOAuth2(config.username, config.secret);
        } catch (e) {
          if (e.toString().contains('AUTHENTICATE failed')) {
            logger.e(
              "IMAP AUTHENTICATE failed. This usually means the token was "
              "rejected by the provider.",
            );
          }
          rethrow;
        }
      case EmailAuthType.appPassword:
      case EmailAuthType.password:
        logger.s("Connecting to ${config.provider.displayName} IMAP...");
        await client.login(config.username, config.secret);
    }
  }

  /// DIAGNOSTICS: logs the Outlook token audience and scopes.
  static void _logOutlookTokenDiagnostics(
    String accessToken,
    AppLogger logger,
  ) {
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

        if (aud != "https://outlook.office.com" &&
            aud != "https://graph.microsoft.com") {
          logger.w(
            "WARNING: Access token audience is '$aud', expected 'https://outlook.office.com'.",
          );
        }
      } else {
        logger.i("DEBUG: Token Diagnostics - Access token is opaque.");
      }
    } catch (e) {
      logger.i("DEBUG: Token Diagnostics - Failed to decode token: $e");
    }
  }

  static Future<void> _moveToTrash(
    ImapClient client, {
    required String? folderId,
    required List<int> uids,
    required AppLogger logger,
  }) async {
    final mailboxes = await client.listMailboxes();
    final trashMailbox =
        mailboxes.where((m) => m.isTrash).firstOrNull ??
        mailboxes
            .where(
              (m) =>
                  m.name.toLowerCase() == 'trash' ||
                  m.name.toLowerCase() == 'archive',
            )
            .firstOrNull;

    final trashPath = trashMailbox?.path ?? 'Trash';
    final targetFolder = folderId ?? 'INBOX';

    logger.s(
      "Moving ${uids.length} messages to $trashPath from $targetFolder...",
    );
    await client.selectMailboxByPath(targetFolder);

    final sequence = MessageSequence();
    for (final uid in uids) {
      sequence.add(uid);
    }
    try {
      await client.uidMove(sequence, targetMailboxPath: trashPath);
      logger.s("Cleanup: remote move to $trashPath complete.");
    } catch (e) {
      logger.e("Error during IMAP MOVE: $e. Attempting Copy/Delete fallback.");
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
  }

  /// Upserts one `email_folders` row per mailbox. Role comes from SPECIAL-USE
  /// flags / provider hints; the id is the full IMAP path. Only top-level
  /// mailboxes are listed (non-recursive LIST), for which the path equals the
  /// old leaf-name id, so existing `emails.folder_id` values still resolve.
  static Future<void> _syncFolderList(
    ImapClient client,
    ImapConnectionConfig config,
    Collection collection,
    SendPort clientPort,
  ) async {
    final mailboxes = await client.listMailboxes();
    for (final mailbox in mailboxes) {
      final role = folderRoleFor(
        name: mailbox.name,
        path: mailbox.path,
        flags: mailbox.flags,
        provider: config.provider,
      );
      final folder = EmailFolder(
        id: mailbox.path,
        collectionId: collection.id,
        name: mailbox.name,
        type: role.name,
        path: mailbox.path,
      );
      await writeViaMain(clientPort, 'emailFolder', folder);
    }
  }

  /// Syncs one mailbox: list UIDs, fetch + parse + write new messages, report
  /// UIDs for local cleanup. This is the replaceable unit for incremental
  /// (UID/CONDSTORE) sync.
  static Future<FolderSyncCounts> _syncFolder({
    required ImapClient client,
    required Collection collection,
    required String providerId,
    required String targetFolder,
    required bool force,
    required DateTime? lastScanDate,
    required String appDir,
    required SendPort clientPort,
    required AppLogger logger,
  }) async {
    int totalFound = 0;
    int newEmails = 0;
    int skipped = 0;

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
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        final dateStr =
            "${sinceDate.day}-${monthNames[sinceDate.month - 1]}-${sinceDate.year}";
        searchCriteria = 'SINCE $dateStr';
        logger.i("IMAP: Performing incremental sync SINCE $dateStr");
      }

      final searchResult = await client.uidSearchMessages(
        searchCriteria: searchCriteria,
      );
      allUids = searchResult.matchingSequence?.toList() ?? [];
      totalFound = allUids.length;

      if (searchCriteria == 'ALL') {
        clientPort.send({
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
      return (found: totalFound, added: newEmails, skipped: skipped);
    }

    const int batchSize = 50;
    final reversedUids = allUids.reversed.toList();
    logger.s("Processing ${reversedUids.length} messages in $targetFolder...");

    for (int i = 0; i < reversedUids.length; i += batchSize) {
      final end =
          (i + batchSize < reversedUids.length)
              ? i + batchSize
              : reversedUids.length;
      final batchUids = reversedUids.sublist(i, end);

      final sequence = MessageSequence();
      for (final uid in batchUids) {
        sequence.add(uid);
      }

      FetchImapResult? fetchResult;
      try {
        fetchResult = await client.uidFetchMessages(sequence, 'BODY.PEEK[]');
      } catch (e) {
        logger.w(
          "Batch fetch starting at $i failed ($e). Retrying UIDs individually...",
        );
      }

      final List<MimeMessage> messagesToProcess = [];
      if (fetchResult != null) {
        messagesToProcess.addAll(fetchResult.messages);
      } else {
        for (final uid in batchUids) {
          try {
            final singleSeq = MessageSequence()..add(uid);
            final singleResult = await client.uidFetchMessages(
              singleSeq,
              'BODY.PEEK[]',
            );
            messagesToProcess.addAll(singleResult.messages);
          } catch (singleErr) {
            logger.w(
              "Full fetch failed for UID $uid ($singleErr). Attempting header salvage...",
            );
            final salvagedMsg = await _salvageCorruptedMessage(
              client,
              uid,
              logger,
            );
            if (salvagedMsg != null) {
              messagesToProcess.add(salvagedMsg);
            }
          }
        }
      }

      List<Email> emailBatch = [];
      for (final message in messagesToProcess) {
        final msgDate = message.decodeDate() ?? DateTime.now();

        // Refine incremental check with second-level precision
        if (!force && lastScanDate != null) {
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
          providerId: providerId,
          targetFolder: targetFolder,
          appDir: appDir,
          clientPort: clientPort,
          logger: logger,
        );
        emailBatch.add(emailObj);
        newEmails++;
      }

      if (emailBatch.isNotEmpty) {
        await writeViaMain(clientPort, 'emailBatch', emailBatch);
        clientPort.send({'type': 'refresh'});
      }
    }

    return (found: totalFound, added: newEmails, skipped: skipped);
  }

  /// Attempts to fetch header-only metadata for a message whose full body
  /// fetch threw an encoding exception, preserving Subject, From, To, Date, and ID.
  static Future<MimeMessage?> _salvageCorruptedMessage(
    ImapClient client,
    int uid,
    AppLogger logger,
  ) async {
    try {
      final singleSeq = MessageSequence()..add(uid);
      final result = await client.uidFetchMessages(
        singleSeq,
        'BODY.PEEK[HEADER]',
      );
      if (result.messages.isNotEmpty) {
        final msg = result.messages.first;
        logger.i(
          "Salvaged header metadata for message UID $uid (Subject: ${msg.decodeSubject()})",
        );
        return msg;
      }
    } catch (e) {
      logger.w("Could not salvage header for message UID $uid: $e");
    }
    return null;
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
    required String targetFolderPath,
    required String extractionRoot,
    required String appDir,
    required AppLogger logger,
    // Needed to tell an embedded image from a real attachment: the body is
    // what says which parts it references. See `InlineAttachment`.
    String? htmlBody,
  }) async {
    List<db_file.File> files = [];
    await io.Directory(targetFolderPath).create(recursive: true);
    final thumbnailCache = ThumbnailCache(appDir);

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

      // An HTML message drags in every spacer, logo and tracking pixel as a
      // real MIME part. Flagging them here is what keeps them out of the photo
      // grid and the embedding queue further downstream.
      final contentId = InlineAttachment.normalizeContentId(
        part.getHeaderValue('content-id'),
      );
      final isInline = InlineAttachment.isInline(
        contentId: contentId,
        fileName: fileName,
        htmlBody: htmlBody,
        dispositionInline:
            part.getHeaderContentDisposition()?.disposition ==
            ContentDisposition.inline,
      );

      Uint8List? content;
      try {
        content = part.decodeContentBinary();
      } catch (e) {
        // Malformed base64 / encoding errors — skip this attachment only.
        logger.w(
          'ImapScanner: Could not decode attachment $fileName (encoding error): $e',
        );
        continue;
      }

      try {
        if (content != null && content.isNotEmpty) {
          final file = io.File(
            p.join(targetFolderPath, '${safeMessageId}_$fileName'),
          );
          await file.writeAsBytes(content);

          final fileId = const Uuid().v5(
            Namespace.url.value,
            'file:email:${collection.id}:$messageId:$fileName',
          );

          String? thumbnail;
          if (mapMimeType(part.mediaType.text) ==
              FilesConstants.mimeTypeImage) {
            try {
              thumbnail = await ThumbnailGenerator().generate(
                collection.id,
                fileId,
                file.path,
                FilesConstants.mimeTypeImage,
                thumbnailCache,
              );
            } catch (e) {
              logger.w(
                'ImapScanner: Failed to generate thumbnail for ${file.path}: $e',
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
              'ImapScanner: Failed to compute relative path for ${file.path}: $e',
            );
          }

          final f = db_file.File(
            id: fileId,
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
            contentId: contentId,
            isInline: isInline,
          );
          files.add(f);
        }
      } catch (e) {
        logger.w('ImapScanner: Failed to save attachment $fileName: $e');
      }
    }
    return files;
  }

  static Future<void> _ensureFolderHierarchy({
    required SendPort clientPort,
    required Collection collection,
    required String extractionRoot,
    required String labelName,
    required String year,
    required DateTime msgDate,
  }) async {
    final labelAbsPath = p.normalize(p.join(extractionRoot, labelName));
    final yearAbsPath = p.normalize(p.join(labelAbsPath, year));

    await writeViaMain(
      clientPort,
      'folder',
      _createFolderObj(
        absPath: labelAbsPath,
        extractionRoot: extractionRoot,
        name: labelName,
        collectionId: collection.id,
        date: msgDate,
      ),
    );
    await writeViaMain(
      clientPort,
      'folder',
      _createFolderObj(
        absPath: yearAbsPath,
        extractionRoot: extractionRoot,
        name: year,
        collectionId: collection.id,
        date: msgDate,
      ),
    );
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

  static Future<Email> _parseAndProcessMessage({
    required MimeMessage message,
    required Collection collection,
    required String providerId,
    required String targetFolder,
    required String appDir,
    required SendPort clientPort,
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
          'email:$providerId:${collection.id}:$targetFolder:${uid ?? const Uuid().v4()}',
        );

    String? plainBody;
    try {
      plainBody = message.decodeTextPlainPart();
    } catch (e) {
      logger.w("enough_mail decodeTextPlainPart error for $emailId: $e");
    }

    String? htmlBody;
    try {
      htmlBody = message.decodeTextHtmlPart();
    } catch (e) {
      logger.w("enough_mail decodeTextHtmlPart error for $emailId: $e");
    }

    if (plainBody == null) {
      try {
        final part = message.allPartsFlat.cast<MimePart?>().firstWhere(
          (p) => p?.mediaType.text.toLowerCase().contains('plain') ?? false,
          orElse: () => null,
        );
        if (part != null) {
          final rawBytes = part.decodeContentBinary();
          if (rawBytes != null && rawBytes.isNotEmpty) {
            plainBody = EmailDecodingHelper.decodeQuotedPrintable(rawBytes);
          }
        }
      } catch (_) {}
    }

    if (htmlBody == null) {
      try {
        final part = message.allPartsFlat.cast<MimePart?>().firstWhere(
          (p) => p?.mediaType.text.toLowerCase().contains('html') ?? false,
          orElse: () => null,
        );
        if (part != null) {
          final rawBytes = part.decodeContentBinary();
          if (rawBytes != null && rawBytes.isNotEmpty) {
            htmlBody = EmailDecodingHelper.decodeQuotedPrintable(rawBytes);
          }
        }
      } catch (_) {}
    }

    String subject;
    try {
      subject = message.decodeSubject() ?? '(no subject)';
    } catch (_) {
      subject = message.getHeaderValue('Subject') ?? '(no subject)';
    }

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
      subject: subject,
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
      final extractionRoot = p.normalize(
        p.join(appDir, 'files', 'email', collection.id),
      );
      final absoluteYearPath = p.normalize(
        p.join(extractionRoot, labelName, year),
      );

      await _ensureFolderHierarchy(
        clientPort: clientPort,
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
        extractionRoot: extractionRoot,
        appDir: appDir,
        logger: logger,
        htmlBody: htmlBody,
      );
      emailObj.attachments = attachments;
      if (attachments.isNotEmpty) {
        await writeViaMain(clientPort, 'batchFile', attachments);
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
