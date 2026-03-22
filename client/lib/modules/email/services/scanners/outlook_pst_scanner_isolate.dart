import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/email/services/get_emails_service.dart';
import 'package:uuid/uuid.dart';

import 'package:http/http.dart' as http;


class OutlookPstScannerIsolate {
  final RootIsolateToken? token;
  final SendPort? dbWriterPort;
  final String appDir;
  final String serverUrl;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  OutlookPstScannerIsolate({
    this.token,
    this.dbWriterPort,
    required this.appDir,
    required this.serverUrl,
  });

  Future<void> start(Collection collection, {bool force = false}) async {
    if (dbWriterPort == null) {
      throw Exception("dbWriterPort is required for OutlookPstScannerIsolate");
    }

    ReceivePort receivePort = ReceivePort("OutlookPstScannerIsolateClient");

    Map<String, dynamic> args = {
      'token': token ?? RootIsolateToken.instance,
      'port': receivePort.sendPort,
      'dbWriterPort': dbWriterPort,
      'collection': collection,
      'appDir': appDir,
      'serverUrl': serverUrl,
    };


    _isolate = await Isolate.spawn(OutlookPstScannerIsolateWorker.worker, args);

    receivePort.listen((message) {
      if (message is Map) {
        if (message['type'] == 'refresh') {
          // Trigger UI refresh
          GetEmailsService.instance.invoke(
            EmailServiceCommand(collection, sortColumn: "date", sortAsc: false),
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

class OutlookPstScannerIsolateWorker {
  static Future<void> worker(Map<String, dynamic> workerArgs) async {
    final RootIsolateToken? token = workerArgs['token'];
    final SendPort clientPort = workerArgs['port'];
    final SendPort dbWriterPort = workerArgs['dbWriterPort'];
    final Collection collection = workerArgs['collection'];
    final String appDir = workerArgs['appDir'];
    final String? serverUrl = workerArgs['serverUrl'];

    
    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);
    
    // 1. Prepare extraction root for attachments
    // Using a folder relative to the collection name in the storage workspace
    final extractionRoot = p.join(appDir, 'files', 'email', collection.id);
    if (!io.Directory(extractionRoot).existsSync()) {
      io.Directory(extractionRoot).createSync(recursive: true);
    }

    logger.i("PST Scanner: Started parsing ${collection.path} -> $extractionRoot");

    if (serverUrl == null) {
       logger.e("PST Scanner: serverUrl is missing!");
       Isolate.exit(clientPort, {'error': 'missing_server_url'});
    }

    // 2. Call FastAPI endpoint
    logger.i("PST Scanner: Calling AI Chat API at $serverUrl/import/pst");
    
    final client = http.Client();
    final request = http.Request('POST', Uri.parse("$serverUrl/import/pst"));
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'file_path': collection.path,
      'output_dir': extractionRoot,
    });

    final response = await client.send(request);
    
    if (response.statusCode != 200) {
      logger.e("PST Scanner: API failed with status ${response.statusCode}");
      Isolate.exit(clientPort, {'error': 'api_failed'});
    }

    // Keep track of internal IDs
    final Map<String, String> folderPathToId = {};
    int count = 0;

    // 3. Listen to stream output
    await response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        if (line.trim().isEmpty) return;
        final data = jsonDecode(line);


        if (data['type'] == 'folder') {
          final folderId = const Uuid().v4();
          folderPathToId[data['path']] = folderId;

          logger.d("PST Folder: ${data['name']} (Path: ${data['path']}, Messages: ${data['count']})");

          final folder = EmailFolder(
            id: folderId,
            collectionId: collection.id,
            name: data['name'],
            type: 'user',
            parentId: p.dirname(data['path']) == "" || p.dirname(data['path']) == "." 
                ? null 
                : folderPathToId[p.dirname(data['path'])], 
          );
          
          dbWriterPort.send({'type': 'email_folder', 'folder': folder});
        } 
        else if (data['type'] == 'email') {
          final emailId = const Uuid().v4();
          final folderId = folderPathToId[data['folder']] ?? 'INBOX';

          final email = Email(
            id: emailId,
            collectionId: collection.id,
            date: DateTime.tryParse(data['date'] ?? "") ?? DateTime.now(),
            from: data['sender'] ?? "Unknown",
            to: (data['to'] as List?)?.map((e) => e.toString()).toList() ?? [], 
            cc: (data['cc'] as List?)?.map((e) => e.toString()).toList() ?? [],
            subject: data['subject'] ?? "(No Subject)",
            plainBody: data['body'] ?? "",
            htmlBody: data['html_body'] ?? "",
            folderId: folderId,
            isRead: true,
            hasAttachments: (data['attachments'] as List?)?.isNotEmpty ?? false,
            isDeleted: false,
          );

          dbWriterPort.send({'type': 'batch_email', 'emails': [email]});

          // Process attachments
          for (var att in data['attachments']) {
            final fileId = const Uuid().v4();
            final file = File(
              id: fileId,
              name: att['name'],
              path: att['path'],
              parent: extractionRoot,
              dateCreated: email.date,
              dateLastModified: email.date,
              collectionId: collection.id,
              contentType: att['contentType'] ?? 'application/octet-stream',
              size: (att['size'] as num).toInt(),
              isDeleted: false,
              emailId: emailId,
            );
            dbWriterPort.send({'type': 'file', 'file': file});
          }

          count++;
          if (count % 50 == 0) {
            // Refresh rate of 50 emails keeps UI updates visible without
            // hammering the main thread with DB queries.
            clientPort.send({'type': 'refresh'});
          }
        } 
        else if (data['type'] == 'debug') {
          logger.d("PST Parser Debug: ${data['message']}");
        }
        else if (data['type'] == 'error') {
          logger.e("PST Parser Error: ${data['message']}");
        }
      } catch (e) {
        logger.e("PST Isolate: Failed to parse line: $line. Error: $e");
      }
    }).asFuture();

    // 4. Cleanup
    logger.i("PST Scanner: Finished processing stream. Processed $count emails.");

    // Update collection status
    dbWriterPort.send({
      'type': 'update_collection_status',
      'id': collection.id,
      'status': 'complete',
      'lastScan': DateTime.now().toIso8601String(),
    });

    clientPort.send({'type': 'refresh'});
    Isolate.exit(clientPort, {'done': true});
  }
}

