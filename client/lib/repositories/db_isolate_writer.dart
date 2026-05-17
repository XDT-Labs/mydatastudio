// dart
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
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
import 'package:logger/logger.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

class DbIsolateWriterClient {
  Isolate? _isolate;
  SendPort? _sendPort;
  SendPort? _writerPort;
  ReceivePort? _receivePort;
  final AppLogger _localLogger = AppLogger(null);

  SendPort? getSendPort() {
    return _writerPort;
  }

  /// Start the DB isolate. Pass the same storagePath and dbName used by the app.
  Future<void> start(
    String storagePath,
    String dbName, {
    bool useMemoryDb = false,
  }) async {
    if (_isolate != null) return;
    _receivePort = ReceivePort("DbIsolateWriterClient");
    Completer<void> completer = Completer<void>();

    RootIsolateToken? token = RootIsolateToken.instance;
    Map<String, dynamic> cfg = {
      'token': token,
      'replyTo': _receivePort!.sendPort,
      'loggerPort':
          _receivePort!.sendPort, // Send logs back through our own ReceivePort
      'path': storagePath,
      'name': dbName,
      'useMemoryDb': useMemoryDb,
      'isTesting': DatabaseManager.isTesting,
      'skipExtensionLoading': DatabaseManager.skipExtensionLoading,
    };

    _isolate = await Isolate.spawn(
      _isolateEntry,
      cfg,
      debugName: 'DbIsolateWriterClientIsolate',
    );

    // list for port to be sent back from isolate
    _receivePort?.listen((data) {
      if (data is SendPort) {
        _writerPort = data;
        if (!completer.isCompleted) {
          completer.complete();
        }
      } else if (data is Map) {
        final type = data['type'];
        final msg = data['message'];

        if (type == 'log') {
          final level = data['level'] as String;
          switch (level) {
            case 'info':
              _localLogger.i('[DbWriter] $msg');
              break;
            case 'error':
              _localLogger.e(
                '[DbWriter] $msg',
                error: data['error'],
                stackTrace: data['stackTrace'],
              );
              break;
            case 'warning':
              _localLogger.w('[DbWriter] $msg');
              break;
            case 'debug':
              _localLogger.d('[DbWriter] $msg');
              break;
            default:
              _localLogger.i('[DbWriter] $msg');
          }
        } else if (type == 'status') {
          _localLogger.s(msg);
        }
      }
    });

    return completer.future;
  }

  /// Send a message to the isolate and await a response.
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
    if (_sendPort == null) return;
    _sendPort!.send({'type': 'close'});
    _receivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _writerPort = null;
  }

  // Isolate entry-point. Must be a top-level function.
  static Future<void> _isolateEntry(Map<String, dynamic> cfg) async {
    final port = ReceivePort();
    BackgroundIsolateBinaryMessenger.ensureInitialized(cfg['token']);

    final SendPort initialReplyTo = cfg['replyTo'] as SendPort;
    final path = cfg['path'] as String?;
    final name = cfg['name'] as String?;
    final useMemoryDb = cfg['useMemoryDb'] as bool? ?? false;
    DatabaseManager.isTesting = cfg['isTesting'] as bool? ?? false;
    DatabaseManager.skipExtensionLoading = cfg['skipExtensionLoading'] as bool? ?? false;

    // Send control port back to the spawner
    initialReplyTo.send(port.sendPort);

    // Set log level inside the isolate
    Logger.level = Level.debug;
    final AppLogger logger = AppLogger(cfg['loggerPort'] as SendPort?);

    // create the AppDatabase inside the isolate
    // We pass inBackground: false because this code is already running
    // inside a dedicated background isolate. Spawning another isolate
    // via createInBackground here adds overhead and file lock races.
    AppDatabase db = AppDatabase(null, path, name, useMemoryDb, false);

    await for (final data in port) {
      if (data is! Map) continue;

      SendPort? replyTo = data['replyTo'] as SendPort?;

      // Retry loop for transient SQLITE_BUSY (code 5) errors.
      // The writer isolate shares the same database file with the main
      // thread's Drift connection (via createInBackground). Even though
      // the main thread is read-only in practice, transient lock contention
      // can occur during WAL checkpoints or Drift's internal transaction
      // management. Retrying here is a centralized safety net.
      const int maxRetries = 5;
      const Duration retryBaseDelay = Duration(milliseconds: 100);

      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        try {
          await _processMessage(data, db, logger, replyTo);
          break; // Success — exit retry loop
        } on SqliteException catch (e) {
          if (e.resultCode == 5 && attempt < maxRetries) {
            final delay = retryBaseDelay * (1 << attempt);
            logger.w(
              'DbIsolateWriter: SQLITE_BUSY on ${data['type']} '
              '(attempt ${attempt + 1}/$maxRetries), '
              'retrying in ${delay.inMilliseconds}ms...',
            );
            await Future.delayed(delay);
            continue;
          }
          // Not SQLITE_BUSY or exhausted retries
          logger.e("Error in DbIsolateWriter: $e", error: e, stackTrace: null);
          replyTo?.send({'error': e.toString()});
        } catch (e, stack) {
          logger.e("Error in DbIsolateWriter: $e", error: e, stackTrace: stack);
          replyTo?.send({'error': e.toString()});
          break; // Non-retryable error
        }
      }
    }
  }

  /// Dispatches a single message to the appropriate handler.
  /// Extracted so the retry loop can re-invoke the entire operation.
  static Future<void> _processMessage(
    Map data,
    AppDatabase db,
    AppLogger logger,
    SendPort? replyTo,
  ) async {
    if (data['type'] == 'file') {
      File f = data['file'] as File;
      logger.d("DbIsolateWriter: Received file upsert for ${f.name} (id: ${f.id}, collectionId: ${f.collectionId})");
      await FileUpsertService.instance.invoke(
        FileUpsertServiceCommand(f, db),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'batch_file') {
      List<File> filesToUpsert = (data['files'] as List).cast<File>();
      await BatchFileUpsertService.instance.invoke(
        BatchFileUpsertServiceCommand(filesToUpsert, db),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'folder') {
      Folder folder = data['folder'] as Folder;
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
      List<Email> emailsToUpsert = (data['emails'] as List).cast<Email>();
      await EmailUpsertService.instance.invoke(
        EmailUpsertServiceCommand(emailsToUpsert, db),
      );
      replyTo?.send({'status': 'ok'});
    } else if (data['type'] == 'email_folder') {
      EmailFolder folder = data['folder'] as EmailFolder;
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
      await (db.update(db.files)..where((t) => t.id.equals(id))).write(
        FilesCompanion(localPath: Value(localPath)),
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
      final existing = await (db.select(db.providers)..where((tbl) => tbl.service.equals(service))).getSingleOrNull();
      if (existing != null) {
        await (db.update(db.providers)..where((tbl) => tbl.service.equals(service))).write(
          ProvidersCompanion(
            clientId: Value(clientId),
            clientSecret: Value(clientSecret),
            apiKey: Value(apiKey),
          ),
        );
      } else {
        await db.into(db.providers).insert(
          ProvidersCompanion(
            service: Value(service),
            clientId: Value(clientId),
            clientSecret: Value(clientSecret),
            apiKey: Value(apiKey),
          ),
        );
      }
      replyTo?.send({'status': 'ok'});
    } else {
      logger.w("Unknown message type: ${data['type']}");
      replyTo?.send({'error': 'Unknown message type: ${data['type']}'});
    }
  }
}
