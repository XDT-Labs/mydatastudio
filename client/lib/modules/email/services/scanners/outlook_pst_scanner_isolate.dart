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

class OutlookPstScannerIsolate {
  final RootIsolateToken? token;
  final SendPort? dbWriterPort;
  final String appDir;
  Isolate? _isolate;
  final AppLogger logger = AppLogger(null);

  OutlookPstScannerIsolate({
    this.token,
    this.dbWriterPort,
    required this.appDir,
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
  static Future<void> worker(Map<String, dynamic> args) async {
    final RootIsolateToken? token = args['token'];
    final SendPort clientPort = args['port'];
    final SendPort dbWriterPort = args['dbWriterPort'];
    final Collection collection = args['collection'];
    final String appDir = args['appDir'];

    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final AppLogger logger = AppLogger(clientPort);
    
    // 1. Resolve Python executable (aichat binary which we added --pst to)
    final executablePath = await _getExecutablePath(appDir, logger);
    if (executablePath == null) {
      logger.e("PST Scanner: AI Chat executable (python environment) not found.");
      Isolate.exit(clientPort, {'error': 'python_not_found'});
    }

    // 2. Prepare extraction root for attachments
    // Using a folder relative to the collection name in the storage workspace
    final extractionRoot = p.join(appDir, 'files', 'email', "${collection.name}_${collection.id}");
    if (!io.Directory(extractionRoot).existsSync()) {
      io.Directory(extractionRoot).createSync(recursive: true);
    }

    logger.i("PST Scanner: Started parsing ${collection.path} -> $extractionRoot");

    // 3. Launch Python process
    final io.Process process = await io.Process.start(
      executablePath,
      ['--pst', '--file', collection.path, '--output_dir', extractionRoot],
    );

    // Keep track of internal IDs
    final Map<String, String> folderPathToId = {};
    int count = 0;

    // 4. Listen to stdout
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        if (line.trim().isEmpty) return;
        final data = jsonDecode(line);

        if (data['type'] == 'folder') {
          final folderId = const Uuid().v4();
          folderPathToId[data['path']] = folderId;

          final folder = EmailFolder(
            id: folderId,
            collectionId: collection.id,
            name: data['name'],
            type: 'user',
            parentId: p.dirname(data['path']) == "." ? null : folderPathToId[p.dirname(data['path'])], 
          );
          
          dbWriterPort.send({'type': 'insert_email_folder', 'data': folder});
        } 
        else if (data['type'] == 'email') {
          final emailId = const Uuid().v4();
          final folderId = folderPathToId[data['folder']] ?? 'INBOX';

          final email = Email(
            id: emailId,
            collectionId: collection.id,
            date: DateTime.parse(data['date']),
            from: data['sender'] ?? "Unknown",
            to: [], 
            cc: [],
            subject: data['subject'] ?? "(No Subject)",
            plainBody: data['body'] ?? "",
            htmlBody: data['html_body'] ?? "",
            folderId: folderId,
            isRead: true,
            hasAttachments: (data['attachments'] as List).isNotEmpty,
            isDeleted: false,
          );

          dbWriterPort.send({'type': 'insert_email', 'data': email});

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
            dbWriterPort.send({'type': 'insert_file', 'data': file});
          }
          count++;
          if (count % 10 == 0) {
            clientPort.send({'type': 'refresh'});
          }
        }
      } catch (e) {
        logger.e("PST Isolate: Failed to parse line: $line. Error: $e");
      }
    });

    // 5. Cleanup
    final exitCode = await process.exitCode;
    logger.i("PST Scanner: Finished with exit code $exitCode. Processed $count emails.");

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

  static Future<String?> _getExecutablePath(String appDir, AppLogger logger) async {
    // This logic follows PythonManager.dart
    // In dev: project_root/app/aichat
    // In bundle: Application Support/aichat
    
    final candidates = [
       p.join(appDir, 'aichat'), // In Application Support
       p.join(appDir, 'aichat.exe'),
       p.join(io.Directory.current.path, 'app', 'aichat'), // Dev mode
       p.join(io.Directory.current.path, 'app', 'aichat.exe'),
    ];

    for (var c in candidates) {
      if (io.File(c).existsSync()) return c;
    }
    
    return null;
  }
}
