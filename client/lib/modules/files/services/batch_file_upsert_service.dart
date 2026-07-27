import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';

import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/app_logger.dart';

/// Module logger. AppLogger writes to the session log file as well as the
/// console; a bare print() only reaches the console.
final AppLogger _logger = AppLogger(null);

class BatchFileUpsertService
    extends RxService<BatchFileUpsertServiceCommand, List<File>> {
  static final BatchFileUpsertService _singleton = BatchFileUpsertService();
  static BatchFileUpsertService get instance => _singleton;

  @override
  Future<List<File>> invoke(BatchFileUpsertServiceCommand command) async {
    isLoading.add(true);

    FileDesktopRepository repo = FileDesktopRepository(command.database);

    try {
      await repo.upsertAll(command.files);
      sink.add(command.files);
    } catch (err) {
      _logger.e("Batch upsert failed: ${err.toString()}");
    }

    isLoading.add(false);
    return Future(() => command.files);
  }
}

class BatchFileUpsertServiceCommand implements RxCommand {
  List<File> files;
  AppDatabase database;
  BatchFileUpsertServiceCommand(this.files, this.database);
}
