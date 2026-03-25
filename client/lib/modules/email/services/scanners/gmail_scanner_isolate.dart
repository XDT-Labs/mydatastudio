import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:googleapis/gmail/v1.dart';
import 'package:path/path.dart' as p;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/modules/email/services/get_emails_service.dart';
import 'package:mydatatools/oauth/google_auth_client.dart';
import 'package:uuid/uuid.dart';

class GmailScannerIsolate {
  final RootIsolateToken? token;
  final SendPort? dbWriterPort;
  final String appDir;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  GmailScannerIsolate({this.token, this.dbWriterPort, required this.appDir});

  Future<void> start(
    Collection collection, {
    String? folderId, // Optional Gmail label ID
    bool force = false,
    SendPort? statusPort, // Added statusPort to forward worker messages
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
      clientPort.send({'type': 'refresh', 'status': 'done'});
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
        emailBatch.add(email);

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
            dbWriterPort: dbWriterPort,
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
            dbWriterPort: dbWriterPort,
            logger: logger,
          );
          email.attachments = attachments;

          for (var file in attachments) {
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
    SendPort? dbWriterPort,
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
            dbWriterPort: dbWriterPort,
            targetFolderPath: effectiveFolderPath,
            logger: logger,
          ),
        );
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

    // 1. Label Folder
    final labelPath = p.normalize(p.join(rootPath, labelName));
    dbWriterPort.send({
      'type': 'folder',
      'folder': _createFolderObj(
        labelPath,
        rootPath,
        labelName,
        collection.id,
        msgDate,
      ),
    });

    // 2. Year Folder
    final yearPath = p.normalize(p.join(labelPath, year));
    dbWriterPort.send({
      'type': 'folder',
      'folder': _createFolderObj(
        yearPath,
        labelPath,
        year,
        collection.id,
        msgDate,
      ),
    });
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
