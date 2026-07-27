import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/app_logger.dart';

/// Module logger. AppLogger writes to the session log file as well as the
/// console; a bare print() only reaches the console.
final AppLogger _logger = AppLogger(null);

class DeleteFileService extends RxService<DeleteFileServiceCommand, bool> {
  static final DeleteFileService _singleton = DeleteFileService._();
  static DeleteFileService get instance => _singleton;
  DeleteFileService._();

  @override
  Future<bool> invoke(DeleteFileServiceCommand command) async {
    isLoading.add(true);

    FileDesktopRepository repo = FileDesktopRepository(command.database);

    try {
      await repo.delete(command.file);
      sink.add(true);
      isLoading.add(false);
      return true;
    } catch (err) {
      _logger.e("Error deleting file from database: $err");
      isLoading.add(false);
      return false;
    }
  }
}

class DeleteFileServiceCommand implements RxCommand {
  final File file;
  final AppDatabase database;
  DeleteFileServiceCommand(this.file, this.database);
}
