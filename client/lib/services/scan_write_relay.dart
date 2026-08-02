import 'dart:isolate';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/email/services/email_folder_upsert_service.dart';
import 'package:mydatastudio/modules/email/services/email_upsert_service.dart';
import 'package:mydatastudio/modules/files/services/batch_file_upsert_service.dart';
import 'package:mydatastudio/modules/files/services/cleanup_deleted_files_service.dart';
import 'package:mydatastudio/modules/files/services/file_upsert_service.dart';
import 'package:mydatastudio/modules/files/services/folder_upsert_service.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';

/// Claims and queues [message] if it's a `{'type': 'dbWrite', ...}` request,
/// returning true so the caller can `return` immediately (the message has
/// been handled). Used by the four scanners that listen via a plain
/// `receivePort.listen(...)` callback (Gmail, Outlook, Yahoo, PST) — the
/// `await for`-based scanners (local filesystem, Google Drive) inline this
/// directly since they don't need [queue] for ordering.
bool tryHandleScanWrite(Object? message, SequentialWriteQueue queue) {
  if (message is! Map || message['type'] != 'dbWrite') return false;
  final replyTo = message['replyTo'] as SendPort;
  queue.add(() async {
    try {
      final result = await handleScanWriteMessage(message);
      replyTo.send({'ok': true, 'result': result});
    } catch (e) {
      replyTo.send({'ok': false, 'error': e.toString()});
    }
  });
  return true;
}

/// Executes a `{'type': 'dbWrite', 'service': ..., 'payload': ...}` message
/// sent by a scanner isolate, writing through the main isolate's single
/// `AppDatabase` connection instead of the isolate opening its own.
///
/// Callers MUST await this before handling the next `dbWrite` message from
/// the same isolate's port. Scanner writes are order-dependent (a folder row
/// must exist before the files inside it are inserted), and this relies on
/// each scanner wrapper's message loop processing one message fully before
/// pulling the next — the same guarantee `handleEmbeddingMessage` didn't need
/// because embedding writes have no ordering dependency on each other.
Future<Map<String, dynamic>> handleScanWriteMessage(
  Map<dynamic, dynamic> message,
) async {
  final db = DatabaseManager.instance.database;
  if (db == null) {
    throw StateError('handleScanWriteMessage: no main database connection');
  }
  final service = message['service'] as String;
  final payload = message['payload'];

  switch (service) {
    case 'batchFile':
      // List<T>.from eagerly type-checks each element (unlike .cast<T>,
      // which is a lazy view and would only throw once the upsert service
      // got around to iterating it — by then the bad payload is out of
      // context and the error just says "type File is not a subtype").
      await BatchFileUpsertService.instance.invoke(
        BatchFileUpsertServiceCommand(List<File>.from(payload as List), db),
      );
      return const {};

    case 'folder':
      await FolderUpsertService.instance.invoke(
        FolderUpsertServiceCommand(payload as Folder, db),
      );
      return const {};

    case 'file':
      await FileUpsertService.instance.invoke(
        FileUpsertServiceCommand(payload as File, db),
      );
      return const {};

    case 'emailFolder':
      await EmailFolderUpsertService.instance.invoke(
        EmailFolderUpsertServiceCommand(payload as EmailFolder, db),
      );
      return const {};

    case 'emailBatch':
      await EmailUpsertService.instance.invoke(
        EmailUpsertServiceCommand(List<Email>.from(payload as List), db),
      );
      return const {};

    case 'fileThumbnail':
      final map = payload as Map;
      final result = await retryOnLock(
        () => db.execute('UPDATE files SET thumbnail = ? WHERE id = ?', [
          map['thumbnailKey'],
          map['fileId'],
        ]),
        label: 'scanWriteRelay.fileThumbnail',
      );
      return {'affectedRows': result.affectedRows};

    case 'cleanupDeletedFiles':
      final map = payload as Map;
      await CleanupDeletedFilesService.instance.invoke(
        CleanupDeletedFilesServiceCommand(
          map['collectionId'] as String,
          map['path'] as String,
          map['scanStartTime'] as DateTime,
          db,
          recursive: map['recursive'] as bool? ?? true,
          isCloud: map['isCloud'] as bool? ?? false,
          isFullScan: map['isFullScan'] as bool? ?? false,
        ),
      );
      return const {};

    case 'fileLocalPath':
      final map = payload as Map;
      await retryOnLock(
        () => db.execute('UPDATE files SET local_path = ? WHERE id = ?', [
          map['localPath'],
          map['fileId'],
        ]),
        label: 'scanWriteRelay.fileLocalPath',
      );
      return const {};

    case 'collectionStatus':
      // A targeted update (scan_status, last_scan_date only) — not the full
      // Collection object the isolate read at scan start, which would
      // otherwise clobber a token refreshed on another connection mid-scan.
      final map = payload as Map;
      await CollectionRepository(db).updateScanStatus(
        map['collectionId'] as String,
        map['scanStatus'] as String,
        map['lastScanDate'] as DateTime,
      );
      return const {};

    default:
      throw ArgumentError(
        'handleScanWriteMessage: unknown service "$service"',
      );
  }
}
