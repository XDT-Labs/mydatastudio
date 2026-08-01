import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/files/services/batch_file_upsert_service.dart';
import 'package:mydatastudio/modules/files/services/cleanup_deleted_files_service.dart';
import 'package:mydatastudio/modules/files/services/folder_upsert_service.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';

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
      await BatchFileUpsertService.instance.invoke(
        BatchFileUpsertServiceCommand((payload as List).cast<File>(), db),
      );
      return const {};

    case 'folder':
      await FolderUpsertService.instance.invoke(
        FolderUpsertServiceCommand(payload as Folder, db),
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
      await CollectionRepository(db).updateCollection(payload as Collection);
      return const {};

    default:
      throw ArgumentError(
        'handleScanWriteMessage: unknown service "$service"',
      );
  }
}
