import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/files/services/repositories/folder_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';
import 'package:mydatastudio/app_logger.dart';

final AppLogger _logger = AppLogger(null);

class FolderUpsertService
    extends RxService<FolderUpsertServiceCommand, Folder?> {
  static final FolderUpsertService _singleton = FolderUpsertService();
  static FolderUpsertService get instance => _singleton;

  @override
  Future<Folder?> invoke(FolderUpsertServiceCommand command) async {
    isLoading.add(true);
    FolderDesktopRepository repo = FolderDesktopRepository(command.database);

    Folder? folder;
    try {
      folder = await retryOnLock(() async {
        Folder? existing = await repo.getByPath(command.folder);
        if (existing == null) {
          return await repo.create(command.folder);
        } else {
          command.folder.id = existing.id; // Preserve existing database ID
          return await repo.update(command.folder);
        }
      }, label: 'FolderUpsertService');
      if (folder != null) {
        sink.add(folder);
      }
    } catch (err) {
      _logger.e('FolderUpsertService error: $err');
    } finally {
      isLoading.add(false);
    }
    return folder;
  }
}

class FolderUpsertServiceCommand implements RxCommand {
  Folder folder;
  AppDatabase database;
  FolderUpsertServiceCommand(this.folder, this.database);
}
