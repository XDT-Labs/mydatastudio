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
import 'package:mydatastudio/helpers/sql_chunks.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/modules/email/services/get_emails_service.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/folder_role_mapper.dart';
import 'package:mydatastudio/modules/email/services/imap/folder_sync_planner.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_removal_planner.dart';
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
  /// [force] The run gate only: if false, returns immediately (Rule 2). Every
  ///   real sync passes true, so it must NOT influence what is synced.
  /// [fullResync] Explicitly ignore stored per-folder sync state and re-fetch
  ///   and re-match every folder. Independent of [force]; nothing in the app
  ///   sets it today.
  /// [statusPort] Optional port to receive status/heartbeat messages.
  Future<void> start(
    Collection collection, {
    String? folderId,
    bool force = false,
    bool fullResync = false,
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
      'fullResync': fullResync,
      'appDir': appDir,
      'dbDir': dbDir,
      // DEK so the worker can decrypt/encrypt collection tokens (AUDIT M2 ph4).
      'vaultDek': VaultManager.instance.dek,
    };

    _isolate = await spawnIsolate(ImapScannerIsolateWorker.worker, args);

    bool isIsolateDone = false;

    void checkDone() {
      if (isIsolateDone) {
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
typedef FolderSyncCounts = ({int found, int added, int skipped, int failed});

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
    final bool fullResync = args['fullResync'] ?? false;
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
        await _recordScanError(clientPort, collection, logger);
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
      final mailboxes = await _syncFolderList(
        client,
        config,
        collection,
        clientPort,
      );

      // 2. Sync Emails: every selectable folder, or just the targeted one.
      final targets =
          folderId != null ? [folderId] : selectableFolderPaths(mailboxes);
      int found = 0, added = 0, skipped = 0;
      final failedFolders = <String>[];
      for (final target in targets) {
        try {
          final counts = await _syncFolder(
            client: client,
            appDb: appDb,
            collection: collection,
            providerId: config.provider.id,
            targetFolder: target,
            fullResync: fullResync,
            appDir: appDir,
            clientPort: clientPort,
            logger: logger,
          );
          found += counts.found;
          added += counts.added;
          skipped += counts.skipped;
          if (counts.failed > 0) failedFolders.add(target);
        } catch (e, stack) {
          failedFolders.add(target);
          logger.e(
            "IMAP sync of folder $target failed: $e",
            error: e,
            stackTrace: stack,
          );
        }
      }

      logger.i(
        "IMAP sync complete: $found found, $added new, $skipped skipped.",
      );

      if (failedFolders.isNotEmpty) {
        // Fail loud: the folders that did sync keep their progress, but the
        // collection must not claim to be up to date.
        logger.e("IMAP sync incomplete; failed folders: $failedFolders");
        await _recordScanError(clientPort, collection, logger);
        clientPort.send({'type': 'refresh', 'status': 'done'});
        return;
      }

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
      // Auth rejected, network down, ...: say so on the collection instead of
      // leaving it looking healthy. (No port = the move_to_trash job.)
      if (clientPort != null && type == 'sync') {
        await _recordScanError(clientPort, collection, logger);
      }
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

  /// Marks the collection's scan as failed, leaving `last_scan_date` alone.
  static Future<void> _recordScanError(
    SendPort clientPort,
    Collection collection,
    AppLogger logger,
  ) async {
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
  static Future<List<Mailbox>> _syncFolderList(
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
    return mailboxes;
  }

  /// Paths of the mailboxes that can be SELECTed (not `\\Noselect` /
  /// `\\NonExistent` containers), INBOX first.
  static List<String> selectableFolderPaths(List<Mailbox> mailboxes) {
    final paths =
        mailboxes
            .where(
              (m) =>
                  !m.hasFlag(MailboxFlag.noSelect) &&
                  !m.hasFlag(MailboxFlag.nonExistent),
            )
            .map((m) => m.path)
            .toList();
    paths.sort((a, b) {
      if (a.toUpperCase() == 'INBOX') {
        return b.toUpperCase() == 'INBOX' ? 0 : -1;
      }
      if (b.toUpperCase() == 'INBOX') return 1;
      return 0;
    });
    return paths;
  }

  static const int _batchSize = 50;

  static Future<void> _emailSync(
    SendPort clientPort,
    String op,
    String collectionId,
    String? folderId, [
    Map<String, Object?> extra = const {},
  ]) => writeViaMain(clientPort, 'emailSync', {
    'op': op,
    'collectionId': collectionId,
    'folderId': folderId,
    ...extra,
  });

  /// Syncs one mailbox incrementally.
  ///
  /// State machine (see [FolderSyncPlanner]):
  ///   reset       - no/changed UIDVALIDITY, or `fullResync`: clear the folder's
  ///                 stored state and UIDs, re-fetch everything, re-match rows
  ///                 we already have by Message-ID.
  ///   skip        - CONDSTORE says UIDNEXT and HIGHESTMODSEQ are unchanged.
  ///   incremental - fetch UIDs > lastSyncedUid, refresh flags (CHANGEDSINCE
  ///                 or full), detect removals by UID-set diff.
  ///
  /// Crash safety: UIDVALIDITY/lastSyncedUid advance only after a batch's rows
  /// are written; UIDNEXT/HIGHESTMODSEQ (which make a later sync skippable)
  /// only after the whole folder is done. A crash therefore re-fetches
  /// (writes are idempotent), it never leaves a gap.
  static Future<FolderSyncCounts> _syncFolder({
    required ImapClient client,
    required AppDatabase appDb,
    required Collection collection,
    required String providerId,
    required String targetFolder,
    required bool fullResync,
    required String appDir,
    required SendPort clientPort,
    required AppLogger logger,
  }) async {
    int newEmails = 0;
    int skipped = 0;
    int failed = 0;
    final cid = collection.id;

    logger.s("Syncing folder: $targetFolder");
    final condstore =
        client.serverInfo.supports('CONDSTORE') ||
        client.serverInfo.supports('QRESYNC');
    final mailbox = await client.selectMailboxByPath(
      targetFolder,
      enableCondStore: condstore,
    );
    final server = ServerFolderState(
      uidValidity: mailbox.uidValidity,
      uidNext: mailbox.uidNext,
      highestModseq: mailbox.highestModSequence,
      supportsCondstore: condstore,
    );

    final storedRows = await appDb.select(
      'SELECT uid_validity, uid_next, highest_modseq, last_synced_uid '
      'FROM email_folders WHERE collection_id = ? AND id = ?',
      [cid, targetFolder],
    );
    final stored =
        storedRows.isEmpty
            ? const StoredFolderSyncState()
            : StoredFolderSyncState(
              uidValidity: storedRows.first['uid_validity'] as int?,
              uidNext: storedRows.first['uid_next'] as int?,
              highestModseq: storedRows.first['highest_modseq'] as int?,
              lastSyncedUid: storedRows.first['last_synced_uid'] as int?,
            );

    final plan = FolderSyncPlanner.plan(
      stored,
      server,
      fullResync: fullResync,
    );
    if (plan.skip) {
      logger.s("$targetFolder unchanged since last sync.");
      return (found: 0, added: 0, skipped: 0, failed: 0);
    }
    if (plan.reset) {
      logger.i(
        "$targetFolder: full resync (UIDVALIDITY ${server.uidValidity}).",
      );
      await _emailSync(clientPort, 'resetFolder', cid, targetFolder);
    }

    // The folder's full UID list serves three purposes: what is new, what
    // vanished, and it sidesteps the `n:*` quirk (a range starting past the
    // end still returns the last message).
    final remoteResult = await client.uidSearchMessages(searchCriteria: 'ALL');
    final remote = (remoteResult.matchingSequence?.toList() ?? <int>[])..sort();
    final remoteSet = remote.toSet();
    final newUids = remote.where((u) => u > plan.fetchAfterUid).toList();
    int lastSynced = plan.fetchAfterUid;
    logger.s(
      "$targetFolder: ${remote.length} on server, ${newUids.length} new.",
    );

    for (int i = 0; i < newUids.length; i += _batchSize) {
      final batchUids = newUids.sublist(
        i,
        i + _batchSize < newUids.length ? i + _batchSize : newUids.length,
      );
      final heads = await _fetchHeaderInfo(client, batchUids, logger);

      // Dedupe by Message-ID within the collection before downloading bodies.
      final known = await _lookupByMessageId(appDb, cid, [
        for (final h in heads.values)
          if (h.messageId != null) h.messageId!,
      ]);
      final toFetch = <int>[];
      final rematch = <Map<String, Object?>>[];
      final alsoHere = <String>[];
      final seenInBatch = <String>{};
      for (final uid in batchUids) {
        final head = heads[uid];
        final mid = head?.messageId;
        if (mid != null) {
          final existing = known[mid];
          if (existing != null) {
            if (existing.isDeleted) {
              // Hidden on purpose (delete policy / user); don't resurrect it.
            } else if (existing.folderId == targetFolder) {
              if (existing.uid == null) {
                rematch.add({
                  'id': existing.id,
                  'uid': uid,
                  'isRead': head!.seen,
                });
              }
              // else: same Message-ID twice in this folder; one row is enough.
            } else {
              alsoHere.add(existing.id);
            }
            skipped++;
            continue;
          }
          if (!seenInBatch.add(mid)) {
            skipped++;
            continue;
          }
        }
        toFetch.add(uid);
      }

      final messages = await _fetchFullMessages(client, toFetch, logger);
      final fetchedUids = messages.map((m) => m.uid).toSet();
      final lost = toFetch.where((u) => !fetchedUids.contains(u)).length;
      if (lost > 0) {
        // Unfetchable even by header salvage: skipped so one corrupt message
        // can't wedge the folder forever, but reported as a failure.
        failed += lost;
        logger.e("$targetFolder: $lost message(s) could not be fetched.");
      }

      final emailBatch = <Email>[];
      for (final message in messages) {
        // Messages without a Message-ID were never in `known`.
        final mid = message.getHeaderValue('Message-ID')?.trim();
        if (mid != null && heads[message.uid] == null) {
          // Header prefetch failed: dedupe now, on the full message.
          final again = (await _lookupByMessageId(appDb, cid, [mid]))[mid];
          if (again != null) {
            if (again.folderId == targetFolder && again.uid == null) {
              rematch.add({
                'id': again.id,
                'uid': message.uid,
                'isRead': message.isSeen,
              });
            } else if (again.folderId != targetFolder && !again.isDeleted) {
              alsoHere.add(again.id);
            }
            skipped++;
            continue;
          }
        }
        emailBatch.add(
          await _parseAndProcessMessage(
            message: message,
            collection: collection,
            providerId: providerId,
            targetFolder: targetFolder,
            appDir: appDir,
            clientPort: clientPort,
            logger: logger,
            isRead: heads[message.uid]?.seen ?? message.isSeen,
          ),
        );
        newEmails++;
      }

      if (emailBatch.isNotEmpty) {
        await writeViaMain(clientPort, 'emailBatch', emailBatch);
      }
      if (rematch.isNotEmpty) {
        await _emailSync(clientPort, 'rematch', cid, targetFolder, {
          'rows': rematch,
        });
      }
      if (alsoHere.isNotEmpty) {
        await _emailSync(clientPort, 'addMembership', cid, targetFolder, {
          'ids': alsoHere,
        });
      }
      lastSynced = batchUids.last;
      await _emailSync(clientPort, 'saveFolderState', cid, targetFolder, {
        'uidValidity': server.uidValidity,
        'uidNext': plan.reset ? null : stored.uidNext,
        'highestModseq': plan.reset ? null : stored.highestModseq,
        'lastSyncedUid': lastSynced,
      });
      clientPort.send({'type': 'refresh'});
    }

    // Local primary rows of this folder: flags and removals both need them.
    final localRows = await _localPrimaryRows(appDb, cid, targetFolder);

    // Flags: server state wins for already-synced mail.
    if (plan.flagSync != FlagSync.none && plan.fetchAfterUid > 0) {
      final readByUid = await _changedFlags(client, plan, localRows, logger);
      if (readByUid.isNotEmpty) {
        await _emailSync(clientPort, 'setRead', cid, targetFolder, {
          'readByUid': readByUid,
        });
      }
    }

    // Removals.
    final policy = collection.emailDeletePolicy;
    if (policy != EmailDeletePolicy.keep) {
      await _dropVanishedSecondary(
        client: client,
        appDb: appDb,
        cid: cid,
        folder: targetFolder,
        remote: remote,
        localRows: localRows,
        clientPort: clientPort,
        logger: logger,
      );
    }
    final vanished = ImapRemovalPlanner.vanished(
      [for (final r in localRows) r.row],
      remoteSet,
      afterReset: plan.reset,
    );
    if (vanished.isNotEmpty) {
      await _resolveVanished(
        client: client,
        cid: cid,
        folder: targetFolder,
        vanished: vanished,
        policy: policy,
        clientPort: clientPort,
        logger: logger,
      );
    }

    // Folder done: only now record what makes a later sync skippable.
    int finalLast = lastSynced;
    if (remote.isNotEmpty && remote.last > finalLast) finalLast = remote.last;
    if (remote.isEmpty && finalLast == 0 && server.uidNext != null) {
      finalLast = server.uidNext! - 1;
    }
    await _emailSync(clientPort, 'saveFolderState', cid, targetFolder, {
      'uidValidity': server.uidValidity,
      'uidNext': server.uidNext,
      'highestModseq': server.highestModseq,
      'lastSyncedUid': finalLast,
    });
    clientPort.send({'type': 'refresh'});

    return (
      found: remote.length,
      added: newEmails,
      skipped: skipped,
      failed: failed,
    );
  }

  static Future<List<_LocalRow>> _localPrimaryRows(
    AppDatabase db,
    String cid,
    String folder,
  ) async {
    final rows = await db.select(
      'SELECT id, uid, message_id, labels, is_read FROM emails '
      'WHERE collection_id = ? AND folder_id = ? AND is_deleted = 0',
      [cid, folder],
    );
    return [
      for (final r in rows)
        _LocalRow(
          LocalImapRow(
            id: r['id'] as String,
            uid: r['uid'] as int?,
            messageId: r['message_id'] as String?,
            labels: _splitLabels(r['labels'] as String?),
          ),
          (r['is_read'] as int? ?? 0) != 0,
        ),
    ];
  }

  static List<String> _splitLabels(String? s) =>
      (s == null || s.isEmpty) ? <String>[] : s.split(',');

  /// Existing emails of the collection by Message-ID (any folder, any state).
  static Future<Map<String, _KnownEmail>> _lookupByMessageId(
    AppDatabase db,
    String cid,
    List<String> messageIds,
  ) async {
    final out = <String, _KnownEmail>{};
    for (final chunk in sqlChunks(messageIds.toSet().toList())) {
      final ph = List.filled(chunk.length, '?').join(',');
      final rows = await db.select(
        'SELECT id, message_id, folder_id, uid, is_deleted FROM emails '
        'WHERE collection_id = ? AND message_id IN ($ph)',
        [cid, ...chunk],
      );
      for (final r in rows) {
        out.putIfAbsent(
          r['message_id'] as String,
          () => _KnownEmail(
            id: r['id'] as String,
            folderId: r['folder_id'] as String?,
            uid: r['uid'] as int?,
            isDeleted: (r['is_deleted'] as int? ?? 0) != 0,
          ),
        );
      }
    }
    return out;
  }

  /// `FLAGS` + `Message-ID` for [uids] without downloading bodies. Failure is
  /// non-fatal (empty map): the caller falls back to deduping after the full
  /// fetch.
  static Future<Map<int, _HeadInfo>> _fetchHeaderInfo(
    ImapClient client,
    List<int> uids,
    AppLogger logger,
  ) async {
    try {
      final result = await client.uidFetchMessages(
        MessageSequence.fromIds(uids, isUid: true),
        '(FLAGS BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])',
      );
      return {
        for (final m in result.messages)
          if (m.uid != null)
            m.uid!: _HeadInfo(
              messageId: m.getHeaderValue('Message-ID')?.trim(),
              seen: m.isSeen,
            ),
      };
    } catch (e) {
      logger.w("Header prefetch failed ($e); deduping after full fetch.");
      return {};
    }
  }

  /// Full bodies for [uids], one at a time when a batch fetch fails, with
  /// header-only salvage for messages enough_mail cannot decode.
  static Future<List<MimeMessage>> _fetchFullMessages(
    ImapClient client,
    List<int> uids,
    AppLogger logger,
  ) async {
    if (uids.isEmpty) return [];
    final seq = MessageSequence.fromIds(uids, isUid: true);
    try {
      return (await client.uidFetchMessages(seq, 'BODY.PEEK[]')).messages;
    } catch (e) {
      logger.w("Batch fetch failed ($e). Retrying UIDs individually...");
    }
    final out = <MimeMessage>[];
    for (final uid in uids) {
      try {
        final single = await client.uidFetchMessages(
          MessageSequence.fromIds([uid], isUid: true),
          'BODY.PEEK[]',
        );
        out.addAll(single.messages);
      } catch (singleErr) {
        logger.w(
          "Full fetch failed for UID $uid ($singleErr). Attempting header salvage...",
        );
        final salvaged = await _salvageCorruptedMessage(client, uid, logger);
        if (salvaged != null) out.add(salvaged);
      }
    }
    return out;
  }

  /// Seen-flag changes for already-synced mail (UIDs <= the stored
  /// lastSyncedUid), as `uid -> isRead`, limited to rows that actually differ.
  static Future<Map<int, bool>> _changedFlags(
    ImapClient client,
    FolderSyncPlan plan,
    List<_LocalRow> localRows,
    AppLogger logger,
  ) async {
    final localReadByUid = {
      for (final r in localRows)
        if (r.row.uid != null) r.row.uid!: r.isRead,
    };
    final result = await client.uidFetchMessages(
      MessageSequence.fromRange(1, plan.fetchAfterUid, isUidSequence: true),
      'FLAGS',
      changedSinceModSequence:
          plan.flagSync == FlagSync.changedSince
              ? plan.changedSinceModseq
              : null,
    );
    final out = <int, bool>{};
    for (final m in result.messages) {
      final uid = m.uid;
      if (uid == null || !localReadByUid.containsKey(uid)) continue;
      if (localReadByUid[uid] != m.isSeen) out[uid] = m.isSeen;
    }
    return out;
  }

  /// Secondary memberships (this folder is only in `labels`) whose message is
  /// no longer in this folder: drop the label. The message lives on in its
  /// primary folder; if that goes too, its own sync handles it.
  static Future<void> _dropVanishedSecondary({
    required ImapClient client,
    required AppDatabase appDb,
    required String cid,
    required String folder,
    required List<int> remote,
    required List<_LocalRow> localRows,
    required SendPort clientPort,
    required AppLogger logger,
  }) async {
    final secondary = await appDb.select(
      'SELECT id, message_id FROM emails WHERE collection_id = ? '
      'AND folder_id != ? AND is_deleted = 0 '
      "AND instr(',' || labels || ',', ?) > 0",
      [cid, folder, ',$folder,'],
    );
    if (secondary.isEmpty) return;
    final remoteSet = remote.toSet();
    final primaryPresent =
        localRows
            .where((r) => r.row.uid != null && remoteSet.contains(r.row.uid))
            .length;
    if (!ImapRemovalPlanner.secondaryScanNeeded(
      primaryPresent: primaryPresent,
      secondaryCount: secondary.length,
      remoteCount: remote.length,
    )) {
      return;
    }
    final remoteIds = <String>{};
    for (int i = 0; i < remote.length; i += 500) {
      final end = i + 500 < remote.length ? i + 500 : remote.length;
      final heads = await _fetchHeaderInfo(
        client,
        remote.sublist(i, end),
        logger,
      );
      for (final h in heads.values) {
        if (h.messageId != null) remoteIds.add(h.messageId!);
      }
    }
    final gone = ImapRemovalPlanner.goneFromSecondary([
      for (final r in secondary)
        LocalImapRow(
          id: r['id'] as String,
          uid: null,
          messageId: r['message_id'] as String?,
          labels: const [],
        ),
    ], remoteIds);
    if (gone.isNotEmpty) {
      await _emailSync(clientPort, 'dropMembership', cid, folder, {
        'ids': [for (final r in gone) r.id],
      });
    }
  }

  /// A message left [folder]. If another folder still holds it, that copy
  /// becomes the primary (nothing is deleted or hidden); otherwise the
  /// account's delete policy applies.
  static Future<void> _resolveVanished({
    required ImapClient client,
    required String cid,
    required String folder,
    required List<LocalImapRow> vanished,
    required EmailDeletePolicy policy,
    required SendPort clientPort,
    required AppLogger logger,
  }) async {
    final expired = <String>[];
    final promotions = <Map<String, Object?>>[];
    for (final row in vanished) {
      var promoted = false;
      if (row.messageId != null) {
        final remaining = List<String>.of(row.labels);
        for (final other in row.labels) {
          final uid = await _findUid(client, other, row.messageId!, logger);
          remaining.remove(other);
          if (uid != null) {
            promotions.add({
              'id': row.id,
              'folderId': other,
              'uid': uid,
              'labels': remaining,
            });
            promoted = true;
            break;
          }
        }
      }
      if (!promoted) expired.add(row.id);
    }
    if (promotions.isNotEmpty) {
      await _emailSync(clientPort, 'promote', cid, folder, {
        'moves': promotions,
      });
    }
    if (expired.isNotEmpty && policy != EmailDeletePolicy.keep) {
      logger.i(
        "${expired.length} message(s) removed from $folder; "
        "applying policy ${policy.dbValue}.",
      );
      await _emailSync(clientPort, 'applyDeletePolicy', cid, folder, {
        'ids': expired,
      });
    }
  }

  /// UID of the message with [messageId] in [folder], or null (also when the
  /// folder itself is gone). Selects [folder].
  static Future<int?> _findUid(
    ImapClient client,
    String folder,
    String messageId,
    AppLogger logger,
  ) async {
    try {
      await client.selectMailboxByPath(folder);
      final quoted = messageId.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      final r = await client.uidSearchMessages(
        searchCriteria: 'HEADER Message-ID "$quoted"',
      );
      final uids = r.matchingSequence?.toList() ?? <int>[];
      return uids.isEmpty ? null : uids.first;
    } catch (e) {
      logger.w("Could not look up $messageId in $folder: $e");
      return null;
    }
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
    bool isRead = false,
  }) async {
    final messageId = message.getHeaderValue('Message-ID')?.trim();
    final int? uid = message.uid;

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
      isRead: isRead,
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

class _HeadInfo {
  const _HeadInfo({required this.messageId, required this.seen});
  final String? messageId;
  final bool seen;
}

class _KnownEmail {
  const _KnownEmail({
    required this.id,
    required this.folderId,
    required this.uid,
    required this.isDeleted,
  });
  final String id;
  final String? folderId;
  final int? uid;
  final bool isDeleted;
}

class _LocalRow {
  const _LocalRow(this.row, this.isRead);
  final LocalImapRow row;
  final bool isRead;
}
