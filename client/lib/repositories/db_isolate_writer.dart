import 'dart:async';
import 'dart:isolate';

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/repositories/database_repository.dart';
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/services/file_upsert_service.dart';
import 'package:mydatatools/modules/files/services/folder_upsert_service.dart';
import 'package:mydatatools/modules/files/services/cleanup_deleted_files_service.dart';
import 'package:mydatatools/modules/files/services/batch_file_upsert_service.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/repositories/user_repository.dart';
import 'package:mydatatools/modules/email/services/email_upsert_service.dart';
import 'package:mydatatools/modules/email/services/email_folder_upsert_service.dart';
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/repositories/collection_repository.dart';

class DbIsolateWriterClient {
  SendPort? _writerPort;
  ReceivePort? _receivePort;
  final AppLogger _localLogger = AppLogger(null);

  SendPort? getSendPort() {
    return _writerPort;
  }

  /// Start the main-thread writer message loop.
  Future<void> start(
    String storagePath,
    String dbName, {
    bool useMemoryDb = false,
  }) async {
    if (_receivePort != null) return;
    _receivePort = ReceivePort("DbIsolateWriterClient");
    _writerPort = _receivePort!.sendPort;

    final db = DatabaseManager.instance.database!;

    _receivePort!.listen((data) async {
      if (data is! Map) return;

      SendPort? replyTo = data['replyTo'] as SendPort?;
      try {
        await processMessage(data, db, _localLogger, replyTo);
      } catch (e, stack) {
        _localLogger.e("Error in DbIsolateWriterClient: $e", error: e, stackTrace: stack);
        replyTo?.send({'error': e.toString()});
      }
    });
  }

  /// Send a message and await a response.
  Future<dynamic> send(Map<String, dynamic> message) async {
    if (_writerPort == null) {
      throw Exception(
        "DbIsolateWriterClient not started or writer port not available",
      );
    }

    final ReceivePort responsePort = ReceivePort();
    try {
      message['replyTo'] = responsePort.sendPort;
      _writerPort!.send(message);
      final response = await responsePort.first;

      if (response is Map && response.containsKey('error')) {
        throw Exception(response['error']);
      }
      return response;
    } finally {
      responsePort.close();
    }
  }

  Future<void> stop() async {
    _receivePort?.close();
    _receivePort = null;
    _writerPort = null;
  }

  /// Dispatches a single message to the appropriate handler.
  static Future<void> processMessage(
    Map data,
    AppDatabase db,
    AppLogger logger,
    SendPort? replyTo,
  ) async {
    if (data['type'] == 'file') {
      final f = data['file'];
      logger.d("DbIsolateWriter: Received file upsert for ${f.name} (id: ${f.id}, collectionId: ${f.collectionId})");
      await FileUpsertService.instance.invoke(
        FileUpsertServiceCommand(f, db),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'batch_file') {
      List filesToUpsert = data['files'] as List;
      await BatchFileUpsertService.instance.invoke(
        BatchFileUpsertServiceCommand(filesToUpsert.cast<File>(), db),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'folder') {
      final folder = data['folder'];
      logger.d("DbIsolateWriter: Received folder upsert for ${folder.name} (path: ${folder.path}, parent: ${folder.parent})");
      await FolderUpsertService.instance.invoke(
        FolderUpsertServiceCommand(folder, db),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'cleanup_deleted') {
      DateTime time = data['scanStartTime'];
      await CleanupDeletedFilesService.instance.invoke(
        CleanupDeletedFilesServiceCommand(
          data['collectionId'] as String,
          data['path'] as String,
          time,
          db,
          recursive: data['recursive'] ?? true,
          isCloud: data['isCloud'] ?? false,
          isFullScan: data['isFullScan'] ?? false,
        ),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'batch_email') {
      List emailsToUpsert = data['emails'] as List;
      await EmailUpsertService.instance.invoke(
        EmailUpsertServiceCommand(emailsToUpsert.cast<Email>(), db),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'email_folder') {
      final folder = data['folder'];
      await EmailFolderUpsertService.instance.invoke(
        EmailFolderUpsertServiceCommand(folder, db),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'delete_file') {
      await FileDesktopRepository(db).delete(data['file'] as File);
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'embedding') {
      await DatabaseRepository(db).upsertFileEmbedding(
        data['fileId'] as String,
        (data['embedding'] as List).cast<double>(),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'user') {
      final v = await UserRepository(db).saveUser(data['user'] as AppUser);
      replyTo?.send({'status': 'ok', 'id': v?.id});
    } else if (data['type'] == 'delete_collection') {
      final id = data['id'] as String;
      logger.d("DbIsolateWriter: Received collection delete for $id");
      await CollectionRepository(db).deleteCollection(id);
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'update_collection_status') {
      final id = data['id'] as String;
      final status = data['status'] as String;
      final lastScan = data['lastScan'] as String?;

      final repo = CollectionRepository(db);
      final col = await repo.collectionById(id);
      if (col != null) {
        col.scanStatus = status;
        if (lastScan != null) {
          col.lastScanDate = DateTime.tryParse(lastScan);
        }
        await repo.updateCollection(col);
      }
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'update_file_local_path') {
      final id = data['id'] as String;
      final localPath = data['localPath'] as String;
      await db.execute(
        'UPDATE files SET local_path = ? WHERE id = ?',
        [localPath, id],
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'get_files_to_download') {
      final id = data['collectionId'] as String;
      final files = await FileDesktopRepository(db).getFilesToDownload(id);
      replyTo?.send({'status': 'ok', 'files': files});
    } else if (data['type'] == 'get_collection_metadata') {
      final id = data['collectionId'] as String;
      final files = await FileDesktopRepository(db).getScanMetadata(id);
      replyTo?.send({'status': 'ok', 'files': files});
    } else if (data['type'] == 'add_collection') {
      final collection = data['collection'] as Collection;
      await CollectionRepository(db).addCollection(collection);
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'update_collection') {
      final collection = data['collection'] as Collection;
      await CollectionRepository(db).updateCollection(collection);
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'delete_emails') {
      final ids = (data['ids'] as List).cast<String>();
      final repo = EmailRepository(db);
      await repo.deleteEmails(ids);
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'cleanup_deleted_outlook') {
      final collection = data['collection'] as Collection;
      final folder = data['folder'] as String;
      final uids = (data['uids'] as List).cast<int>();
      final repo = EmailRepository(db);
      await repo.cleanupDeletedOutlook(collection, folder, uids);
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'cleanup_deleted_yahoo') {
      final collection = data['collection'] as Collection;
      final folder = data['folder'] as String;
      final uids = (data['uids'] as List).cast<int>();
      final repo = EmailRepository(db);
      await repo.cleanupDeletedYahoo(collection, folder, uids);
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'save_provider') {
      final service = data['service'] as String;
      final clientId = data['clientId'] as String;
      final clientSecret = data['clientSecret'] as String;
      final apiKey = data['apiKey'] as String? ?? '';
      await db.execute(
        'INSERT INTO providers (service, client_id, client_secret, api_key) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(service) DO UPDATE SET '
        'client_id = excluded.client_id, '
        'client_secret = excluded.client_secret, '
        'api_key = excluded.api_key',
        [service, clientId, clientSecret, apiKey],
      );
      replyTo?.send({'status': 'ok'});
    } else {
      logger.w("Unknown message type: ${data['type']}");
      replyTo?.send({'error': 'Unknown message type: ${data['type']}'});
    }
  }
}
