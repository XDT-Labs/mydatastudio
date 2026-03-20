import 'dart:isolate';
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
import 'dart:io' as io;
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:uuid/uuid.dart';

class YahooScannerIsolate {
  final RootIsolateToken? token;
  final SendPort? dbWriterPort;
  final String appDir;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  YahooScannerIsolate({
    this.token,
    this.dbWriterPort,
    required this.appDir,
  });

  Future<void> start(
    Collection collection, {
    String? folderId,
    bool force = false,
    SendPort? statusPort,
  }) async {
    if (dbWriterPort == null) {
      throw Exception("dbWriterPort is required for YahooScannerIsolate");
    }

    ReceivePort receivePort = ReceivePort("YahooScannerIsolateClient");

    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'port': receivePort.sendPort,
      'dbWriterPort': dbWriterPort,
      'collection': collection,
      'folderId': folderId,
      'appDir': appDir,
    };

    _isolate = await Isolate.spawn(YahooScannerIsolateWorker.worker, args);

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
            EmailServiceCommand(collection, sortColumn: "date", sortAsc: false, folderId: folderId),
          );
        } else if (message['type'] == 'cleanup_uids') {
          final db = DatabaseManager.instance.appDatabase;
          if (db != null) {
            isCleanupInProgress = true;
            final repo = EmailRepository(db);
            repo.cleanupDeletedYahoo(
              collection,
              message['folder'],
              (message['uids'] as List).cast<int>(),
            ).then((_) {
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
    await Isolate.spawn(YahooScannerIsolateWorker.worker, args);
    
    if (statusPort != null) {
      statusPort.send("Remote delete request sent for ${uids.length} messages");
    }
  }

  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

class YahooScannerIsolateWorker {
  static Future<void> worker(Map<String, dynamic> args) async {
    final RootIsolateToken? token = args['token'];
    final SendPort? clientPort = args['port'];
    final SendPort dbWriterPort = args['dbWriterPort'];
    final Collection collection = args['collection'];
    final String? folderId = args['folderId'];
    final String type = args['type'] ?? 'sync';
    final List<int>? uidsToMove = args['uids'] != null ? (args['uids'] as List).cast<int>() : null;

    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);
    final emailAddress = collection.userId!;
    final appPassword = collection.accessToken!;

    final client = ImapClient(isLogEnabled: false);
    try {
      logger.s("Connecting to Yahoo IMAP for $type...");
      await client.connectToServer('imap.mail.yahoo.com', 993, isSecure: true);
      await client.login(emailAddress, appPassword);

      if (type == 'move_to_trash' && uidsToMove != null && uidsToMove.isNotEmpty) {
        final mailboxes = await client.listMailboxes();
        // Use flag-based discovery first, then fall back to common names
        final trashMailbox = mailboxes.where((m) => m.isTrash).firstOrNull ?? 
                           mailboxes.where((m) => m.name.toLowerCase() == 'trash' || m.name.toLowerCase() == 'archive').firstOrNull;
        
        final trashPath = trashMailbox?.name ?? 'Trash';
        final targetFolder = folderId ?? 'INBOX';
        
        logger.s("Moving ${uidsToMove.length} messages to $trashPath from $targetFolder...");
        await client.selectMailboxByPath(targetFolder);
        
        final sequence = MessageSequence();
        for (final uid in uidsToMove) {
          sequence.add(uid);
        }
        
        try {
          await client.uidMove(sequence, targetMailboxPath: trashPath);
          logger.s("Cleanup: remote move to $trashPath complete.");
        } catch (e) {
          logger.e("Error during IMAP MOVE: $e. Attempting Copy/Delete fallback.");
          // Fallback: Copy -> Delete -> Expunge
          try {
            await client.uidCopy(sequence, targetMailboxPath: trashPath);
            await client.uidStore(sequence, [MessageFlags.deleted], action: StoreAction.add);
            await client.uidExpunge(sequence);
            logger.s("Cleanup: move to Trash completed via fallback.");
          } catch (e2) {
             logger.e("Fallback Copy/Delete failed: $e2");
          }
        }
        
        await client.logout();
        return;
      }

      // 1. Sync Folders
      logger.s("Syncing Yahoo folders...");
      final mailboxes = await client.listMailboxes();
      for (final mailbox in mailboxes) {
        final folder = EmailFolder(
          id: mailbox.name,
          collectionId: collection.id,
          name: mailbox.name,
          type: _getFolderType(mailbox.name),
        );
        dbWriterPort.send({'type': 'email_folder', 'folder': folder});
      }

      // 2. Sync Emails
      final targetFolder = folderId ?? 'INBOX';
      logger.s("Syncing folder: $targetFolder");
      await client.selectMailboxByPath(targetFolder);
      
      // Fetch ALL UIDs to detect deletions
      try {
        final searchResult = await client.uidSearchMessages(searchCriteria: 'ALL');
        final allUids = searchResult.matchingSequence?.toList() ?? [];
        clientPort?.send({
          'type': 'cleanup_uids',
          'folder': targetFolder,
          'uids': allUids,
        });
      } catch (err) {
        logger.e("Failed to fetch all UIDs for folder cleanup: $err");
      }

      logger.s("Fetching up to 100 recent messages...");
      final fetchResult = await client.fetchRecentMessages(messageCount: 100, criteria: 'BODY.PEEK[]');
      logger.s("Fetched ${fetchResult.messages.length} messages.");
      
      List<Email> emailBatch = [];
      for (final message in fetchResult.messages) {
        final messageId = message.getHeaderValue('Message-ID');
        int? uid;
        try {
          uid = (message as dynamic).uid;
        } catch (_) {}

        String emailId = messageId ?? 
            const Uuid().v5(Namespace.url.value, 'email:yahoo:${collection.id}:$targetFolder:${uid ?? const Uuid().v4()}');
        
        final plainBody = message.decodeTextPlainPart();
        final htmlBody = message.decodeTextHtmlPart();
        final snippet = plainBody != null 
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

        if (hasAttachments && collection.downloadAttachments) {
          final labelName = targetFolder;
          final year = msgDate.year.toString();
          final rootPathNormalized = p.normalize(collection.path);
          final absoluteYearPath = p.normalize(p.join(rootPathNormalized, labelName, year));

          await _ensureFolderHierarchy(
            dbWriterPort: dbWriterPort,
            collection: collection,
            labelName: labelName,
            year: year,
            msgDate: msgDate,
          );

          final allParts = _collectAllParts(message);
          final attachments = await _downloadAttachments(
            collection: collection,
            messageId: emailId,
            msgDate: msgDate,
            parts: allParts,
            targetFolderPath: absoluteYearPath,
            dbWriterPort: dbWriterPort,
            logger: logger,
          );
          emailObj.attachments = attachments;
          for (var file in attachments) {
            dbWriterPort.send({'type': 'file', 'file': file});
          }
        }
        emailBatch.add(emailObj);
      }

      if (emailBatch.isNotEmpty) {
        dbWriterPort.send({'type': 'batch_email', 'emails': emailBatch});
      }

      logger.s("Yahoo sync complete.");
      clientPort?.send({'type': 'refresh', 'status': 'done'});
    } catch (e, stack) {
      logger.e("Error in Yahoo Isolate: $e", error: e, stackTrace: stack);
    } finally {
      if (client.isLoggedIn) {
        await client.logout();
      }
      Isolate.exit(clientPort, {'status': 'done'});
    }
  }

  static List<dynamic> _collectAllParts(dynamic part) {
    if (part == null) return [];
    List<dynamic> all = [];
    dynamic data;
    try { data = part.mimeData; } catch (_) { data = part; }

    if (data != null) {
      final parts = data.parts;
      if (parts != null) {
        for (var p in parts) {
          all.add(p);
          all.addAll(_collectAllParts(p));
        }
      }
    }
    return all;
  }

  static Future<List<db_file.File>> _downloadAttachments({
    required Collection collection,
    required String messageId,
    required DateTime msgDate,
    required List<dynamic> parts,
    required String targetFolderPath,
    required SendPort dbWriterPort,
    required AppLogger logger,
  }) async {
    List<db_file.File> files = [];
    await io.Directory(targetFolderPath).create(recursive: true);

    for (var part in parts) {
      String? fileName;
      try { fileName = part.decodeFileName(); } catch (_) {}
      
      if (fileName != null) {
        try {
          final file = io.File(p.join(targetFolderPath, '${messageId}_$fileName'));
          dynamic pPart = part;
          Object? content;
          try { content = pPart.decodeContent(); } catch (_) { try { content = pPart.decode(); } catch (_) {} }
          
          if (content != null) {
            if (content is List<int>) await file.writeAsBytes(content);
            else if (content is String) await file.writeAsString(content);

            final f = db_file.File(
              id: const Uuid().v5(Namespace.url.value, 'file:email:${collection.id}:$messageId:$fileName'),
              collectionId: collection.id,
              name: fileName,
              path: file.path,
              parent: targetFolderPath,
              dateCreated: msgDate,
              dateLastModified: msgDate,
              size: file.lengthSync(),
              contentType: (part as dynamic).mediaType?.toString() ?? 'application/octet-stream',
              isDeleted: false,
              emailId: messageId,
            );
            files.add(f);
          }
        } catch (e) {
          logger.w("YahooScanner: Failed to save attachment: $e");
        }
      }
    }
    return files;
  }

  static Future<void> _ensureFolderHierarchy({
    required SendPort dbWriterPort,
    required Collection collection,
    required String labelName,
    required String year,
    required DateTime msgDate,
  }) async {
    final rootPath = collection.path;
    final labelPath = p.normalize(p.join(rootPath, labelName));
    dbWriterPort.send({'type': 'folder', 'folder': _createFolderObj(labelPath, rootPath, labelName, collection.id, msgDate)});
    final yearPath = p.normalize(p.join(labelPath, year));
    dbWriterPort.send({'type': 'folder', 'folder': _createFolderObj(yearPath, labelPath, year, collection.id, msgDate)});
  }

  static db_folder.Folder _createFolderObj(String path, String parent, String name, String collectionId, DateTime date) {
    return db_folder.Folder(
      id: const Uuid().v5(Namespace.url.value, 'folder:email:$collectionId:$path'),
      collectionId: collectionId,
      name: name,
      path: path,
      parent: parent,
      dateCreated: date,
      dateLastModified: date,
    );
  }

  static String _getFolderType(String name) {
    final n = name.toUpperCase();
    if (n == 'INBOX' || n == 'SENT' || n == 'TRASH' || n == 'SPAM' || n == 'DRAFTS') return 'system';
    return 'user';
  }
}
