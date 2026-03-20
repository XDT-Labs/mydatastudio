import 'dart:isolate';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/services.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/modules/email/services/get_emails_service.dart';
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

    receivePort.listen((message) {
      if (message is Map) {
        if (message['type'] == 'refresh') {
          GetEmailsService.instance.invoke(
            EmailServiceCommand(collection, sortColumn: "date", sortAsc: false, folderId: folderId),
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

class YahooScannerIsolateWorker {
  static Future<void> worker(Map<String, dynamic> args) async {
    final RootIsolateToken? token = args['token'];
    final SendPort clientPort = args['port'];
    final SendPort dbWriterPort = args['dbWriterPort'];
    final Collection collection = args['collection'];
    final String? folderId = args['folderId'];

    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);

    final emailAddress = collection.userId!;
    final appPassword = collection.accessToken!;

    final client = ImapClient(isLogEnabled: false);
    try {
      logger.s("Connecting to Yahoo IMAP...");
      await client.connectToServer('imap.mail.yahoo.com', 993, isSecure: true);
      await client.login(emailAddress, appPassword);

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

      // 2. Sync Emails from selected folder or Inbox
      final targetFolder = folderId ?? 'INBOX';
      logger.s("Syncing folder: $targetFolder");
      
      await client.selectMailboxByPath(targetFolder);
      
      // Fetch recent messages
      final fetchResult = await client.fetchRecentMessages(messageCount: 50, criteria: 'BODY.PEEK[]');
      
      List<Email> emailBatch = [];
      for (final message in fetchResult.messages) {
        final messageId = message.getHeaderValue('Message-ID');
        String emailId = messageId ?? const Uuid().v4();
        
        final plainBody = message.decodeTextPlainPart();
        final htmlBody = message.decodeTextHtmlPart();
        final snippet = plainBody != null 
            ? (plainBody.length > 200 ? plainBody.substring(0, 200) : plainBody)
            : '';

        final emailObj = Email(
          id: emailId,
          collectionId: collection.id,
          date: message.decodeDate() ?? DateTime.now(),
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
          hasAttachments: message.mimeData?.parts != null && message.mimeData!.parts!.length > 1,
          isDeleted: false,
        );
        emailBatch.add(emailObj);
      }

      if (emailBatch.isNotEmpty) {
        dbWriterPort.send({'type': 'batch_email', 'emails': emailBatch});
        clientPort.send({'type': 'refresh'});
      }

      logger.s("Yahoo sync complete.");
    } catch (e, stack) {
      logger.e("Error in Yahoo Isolate: $e", error: e, stackTrace: stack);
    } finally {
      if (client.isLoggedIn) {
        await client.logout();
      }
      Isolate.exit(clientPort, {'status': 'done'});
    }
  }

  static String _getFolderType(String name) {
    final n = name.toUpperCase();
    if (n == 'INBOX' || n == 'SENT' || n == 'TRASH' || n == 'SPAM' || n == 'DRAFTS') {
      return 'system';
    }
    return 'user';
  }
}
