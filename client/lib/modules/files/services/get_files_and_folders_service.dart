import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:mydatatools/modules/files/services/repositories/folder_repository.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/services/rx_service.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';

class GetFileAndFoldersService
    extends RxService<GetFileAndFoldersServiceCommand, List<FileAsset>> {
  static final GetFileAndFoldersService _singleton = GetFileAndFoldersService();
  static get instance => _singleton;
  AppLogger logger = AppLogger(null);

  @override
  Future<List<FileAsset>> invoke(
    GetFileAndFoldersServiceCommand command,
  ) async {
    isLoading.add(true);
    AppDatabase? db = DatabaseManager.instance.database;
    FileDesktopRepository fileRepo = FileDesktopRepository(db!);
    FolderDesktopRepository folderRepo = FolderDesktopRepository(db);

    String path = command.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    // Skip scanner if it's just a refresh-only request
    if (!command.refreshOnly) {
      await ScannerManager.getInstance()
          .getScanner(command.collection)
          ?.start(command.collection, path, false, false);
    }

    List<FileAsset> files = await fileRepo.getByParentPath(command.collection.id, path);
    List<FileAsset> folders = await folderRepo.getByParentPath(command.collection.id, path);

    List<FileAsset> assets = [...files, ...folders];

    sink.add(assets);
    isLoading.add(false);

    return Future(() => assets);
  }
}

class GetFileAndFoldersServiceCommand implements RxCommand {
  Collection collection;
  String path;
  bool refreshOnly;

  GetFileAndFoldersServiceCommand(this.collection, this.path, {this.refreshOnly = false});
}

