import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:googleapis/gmail/v1.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/email/services/get_emails_service.dart';
import 'package:mydatatools/oauth/google_auth_client.dart';
import 'package:uuid/uuid.dart';

class GmailScannerIsolate {
  final RootIsolateToken? token;
  final SendPort? dbWriterPort;
  final String appDir;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  GmailScannerIsolate({
    this.token,
    this.dbWriterPort,
    required this.appDir,
  });

  Future<void> start(
    Collection collection, {
    String? folderId, // Optional Gmail label ID
    bool force = false,
  }) async {
    if (dbWriterPort == null) {
       throw Exception("dbWriterPort is required for GmailScannerIsolate");
    }

    ReceivePort receivePort = ReceivePort("GmailScannerIsolateClient");
    
    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'port': receivePort.sendPort,
      'dbWriterPort': dbWriterPort,
      'collection': collection,
      'folderId': folderId,
      'appDir': appDir,
    };

    _isolate = await Isolate.spawn(GmailScannerIsolateWorker.worker, args);

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

class GmailScannerIsolateWorker {
  static Future<void> worker(Map<String, dynamic> args) async {
    final RootIsolateToken? token = args['token'];
    final SendPort clientPort = args['port'];
    final SendPort dbWriterPort = args['dbWriterPort'];
    final Collection collection = args['collection'];
    final String? folderId = args['folderId'];
    final String appDir = args['appDir'];

    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);

    // Validate/Refresh Token
    String? accessToken;
    try {
      accessToken = await GoogleAuthClient.validateToken(
        collection.accessToken!,
        collection.refreshToken!,
      );
    } catch (e) {
      logger.e("Failed to validate Gmail token: $e");
      Isolate.exit(clientPort, {'error': 'auth_failed'});
    }

    // if validation fails it throws an exception or Isolate.exit is called inside catch block

    Map<String, String> authHeaders = {"Authorization": "Bearer $accessToken"};
    final authHttpClient = GoogleAuthClient(authHeaders);
    final GmailApi gmailApi = GmailApi(authHttpClient);

    try {
      // 1. Sync Labels (Folders)
      logger.s("Syncing Gmail labels...");
      final labelsResponse = await gmailApi.users.labels.list('me');
      final labels = labelsResponse.labels ?? [];
      
      for (var label in labels) {
        final folder = mapLabelToFolder(label, collection.id);
        dbWriterPort.send({'type': 'email_folder', 'folder': folder});
      }

      // 2. Sync Emails
      if (folderId != null) {
        logger.s("Syncing folder: $folderId");
        await _pullEmails(
          gmailApi,
          dbWriterPort,
          clientPort,
          collection,
          appDir,
          accessToken,
          labelId: folderId,
        );
      } else {
        // Default sync: Inbox, Sent, Trash, Spam
        const defaultLabels = ['INBOX', 'SENT', 'TRASH', 'SPAM'];
        for (var label in defaultLabels) {
          logger.s("Syncing label: $label");
          await _pullEmails(
            gmailApi,
            dbWriterPort,
            clientPort,
            collection,
            appDir,
            accessToken,
            labelId: label,
          );
        }
      }

      logger.s("Gmail sync complete.");
      clientPort.send({'type': 'refresh'});
    } catch (e, stack) {
      logger.e("Error in Gmail Isolate: $e", error: e, stackTrace: stack);
    } finally {
      Isolate.exit(clientPort, {'status': 'done'});
    }
  }

  static Future<void> _pullEmails(
    GmailApi gmailApi,
    SendPort dbWriterPort,
    SendPort clientPort,
    Collection collection,
    String appDir,
    String accessToken, {
    String? labelId,
    String? pageToken,
  }) async {
    final logger = AppLogger(clientPort);
    
    final response = await gmailApi.users.messages.list(
      'me',
      labelIds: labelId != null ? [labelId] : null,
      pageToken: pageToken,
      maxResults: 50, // Small batch for responsiveness
    );

    final messages = response.messages ?? [];
    if (messages.isEmpty) return;

    List<Email> emailBatch = [];

    for (var msgRef in messages) {
      try {
        final m = await gmailApi.users.messages.get('me', msgRef.id!, format: 'full');
        
        DateTime msgDate = DateTime.fromMillisecondsSinceEpoch(
          int.parse(m.internalDate!),
        );

        String? subject = _getHeader(m.payload?.headers, 'subject');
        String? from = _getHeader(m.payload?.headers, 'from');
        String? toRaw = _getHeader(m.payload?.headers, 'to');
        String? ccRaw = _getHeader(m.payload?.headers, 'cc');
        String? messageId = _getHeader(m.payload?.headers, 'message-id');

        String? plainBody = _parseBodyParts(m.payload?.parts ?? [], 'text/plain');
        String? htmlBody = _parseBodyParts(m.payload?.parts ?? [], 'text/html');

        // Note: Gmail API doesn't provide a simple "hasAttachments" flag in list view.
        // We check if there are parts with attachmentId or if mimeType is multipart/mixed.
        bool hasAttachments = _checkAttachments(m.payload?.parts ?? []);

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

        emailBatch.add(email);

        // Download attachments if any
        if (hasAttachments) {
           // We could spawn a sub-task or just do it here. 
           // For now, let's keep the existing logic but route via dbWriterPort.
           final attachments = await _downloadAttachments(
             gmailApi,
             collection,
             appDir,
             m.id!,
             msgDate,
             m.payload?.parts ?? [],
           );
           // In this system, attachments are currently stored in Email.attachments
           // and saved by EmailRepository.addEmails? 
           // Actually, the existing code adds them to the Email object.
           // But our drift model for Email doesn't store attachments directly 
           // (it's a join or separate table usually). 
           // Existing Email model has `List<File>? attachments`.
           email.attachments = attachments;
           
           // Send file objects to DbWriter too so they show up in Files module if needed?
           // The existing code didn't seem to do that, it just kept them in the Email object.
           for(var file in attachments) {
             dbWriterPort.send({'type': 'file', 'file': file});
           }
        }

      } catch (e) {
        logger.w("Failed to fetch/parse message ${msgRef.id}: $e");
      }
    }

    if (emailBatch.isNotEmpty) {
      dbWriterPort.send({'type': 'batch_email', 'emails': emailBatch});
      clientPort.send({'type': 'refresh'});
    }

    if (response.nextPageToken != null) {
      await _pullEmails(
        gmailApi,
        dbWriterPort,
        clientPort,
        collection,
        appDir,
        accessToken,
        labelId: labelId,
        pageToken: response.nextPageToken,
      );
    }
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

  static bool _checkAttachments(List<MessagePart> parts) {
    for (var part in parts) {
      if (part.body?.attachmentId != null) return true;
      if (part.parts != null && _checkAttachments(part.parts!)) return true;
    }
    return false;
  }

  static Future<List<File>> _downloadAttachments(
    GmailApi gmailApi,
    Collection collection,
    String appDir,
    String messageId,
    DateTime msgDate,
    List<MessagePart> parts,
  ) async {
    List<File> files = [];
    for (var part in parts) {
      if (part.body?.attachmentId != null) {
        try {
          final attachment = await gmailApi.users.messages.attachments.get(
            'me',
            messageId,
            part.body!.attachmentId!,
          );

          final fileName = part.filename ?? 'unnamed_attachment';
          final sep = io.Platform.pathSeparator;
          final path = '$appDir${sep}files${sep}email${sep}${collection.name}${sep}${msgDate.year}${sep}${msgDate.month}${sep}${msgDate.day}';
          
          await io.Directory(path).create(recursive: true);
          final file = io.File('$path$sep$fileName');
          await file.writeAsBytes(base64Url.decode(attachment.data!));

          final f = File(
            id: const Uuid().v4().toString(),
            collectionId: collection.id,
            name: fileName,
            path: file.path,
            parent: path,
            dateCreated: msgDate,
            dateLastModified: msgDate,
            size: file.lengthSync(),
            contentType: part.mimeType ?? 'application/octet-stream',
            isDeleted: false,
          );
          files.add(f);
        } catch (e) {
          // Log and continue
        }
      }
      if (part.parts != null) {
        files.addAll(await _downloadAttachments(
          gmailApi,
          collection,
          appDir,
          messageId,
          msgDate,
          part.parts!,
        ));
      }
    }
    return files;
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
