import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';
import 'package:mydatastudio/app_logger.dart';

final AppLogger _logger = AppLogger(null);

class FileUpsertService extends RxService<FileUpsertServiceCommand, File> {
  static final FileUpsertService _singleton = FileUpsertService();
  static FileUpsertService get instance => _singleton;

  @override
  Future<File> invoke(FileUpsertServiceCommand command) async {
    isLoading.add(true);
    FileDesktopRepository repo = FileDesktopRepository(command.database);

    File? file;
    try {
      file = await retryOnLock(() async {
        File? existing = await repo.getByPath(command.file);
        if (existing == null) {
          return await repo.create(command.file);
        } else {
          return await repo.update(command.file);
        }
      }, label: 'FileUpsertService');
      if (file != null) {
        sink.add(file);
      }
      return file ?? command.file;
    } catch (err) {
      _logger.e('FileUpsertService error: $err');
      return command.file;
    } finally {
      isLoading.add(false);
    }
  }
}

class FileUpsertServiceCommand implements RxCommand {
  File file;
  AppDatabase database;
  FileUpsertServiceCommand(this.file, this.database);
}
