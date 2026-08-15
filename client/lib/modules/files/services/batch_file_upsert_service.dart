import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';

import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';
import 'package:mydatastudio/app_logger.dart';

/// Module logger. AppLogger writes to the session log file as well as the
/// console; a bare print() only reaches the console.
final AppLogger _logger = AppLogger(null);

class BatchFileUpsertService
    extends RxService<BatchFileUpsertServiceCommand, List<File>> {
  static final BatchFileUpsertService _singleton = BatchFileUpsertService();
  static BatchFileUpsertService get instance => _singleton;

  /// Upserts a batch of files, retrying transient lock contention.
  ///
  /// `upsertAll` writes the batch inside `database.transaction(...)`, so a
  /// competing writer surfaces as `ResqliteTransactionException: database is
  /// locked` — see [retryOnLock]. The whole transaction is retried rather than
  /// falling back to row-by-row: the lock is held against the connection, not a
  /// row, so 100 individual writes would simply fail 100 times, and splitting
  /// the batch would give up the all-or-nothing property the transaction exists
  /// for.
  ///
  /// **Throws on failure.** This used to catch everything, log a line, and
  /// return `command.files` as though the write had succeeded — so a scan could
  /// silently lose a 100-file batch and still report success. Worse, the files
  /// in a lost batch never get their `last_scanned_date` bumped, so the cleanup
  /// pass that follows marks records that are still on disk as deleted. The
  /// caller has to know, so the error now propagates.
  @override
  Future<List<File>> invoke(BatchFileUpsertServiceCommand command) async {
    isLoading.add(true);

    FileDesktopRepository repo = FileDesktopRepository(command.database);

    try {
      await retryOnLock(
        () => repo.upsertAll(command.files),
        label: 'BatchFileUpsertService',
      );
      sink.add(command.files);
      return command.files;
    } catch (err) {
      _logger.e('Batch upsert failed for ${command.files.length} files: $err');
      rethrow;
    } finally {
      isLoading.add(false);
    }
  }
}

class BatchFileUpsertServiceCommand implements RxCommand {
  List<File> files;
  AppDatabase database;
  BatchFileUpsertServiceCommand(this.files, this.database);
}
