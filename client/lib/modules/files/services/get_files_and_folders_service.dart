import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:mydatatools/modules/files/services/repositories/folder_repository.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/services/rx_service.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/helpers/file_path_resolver.dart';
import 'package:path/path.dart' as p;

/// Number of files fetched per page.
const int kFilesPageSize = 200;

class GetFileAndFoldersService
    extends RxService<GetFileAndFoldersServiceCommand, List<FileAsset>> {
  static final GetFileAndFoldersService _singleton =
      GetFileAndFoldersService();
  static GetFileAndFoldersService get instance => _singleton;
  AppLogger logger = AppLogger(null);

  /// Tracks the accumulated pages so load-more can append without reading
  /// the sink (which is typed as `Subject<R>` and has no valueOrNull).
  List<FileAsset> _currentItems = [];

  @override
  Future<List<FileAsset>> invoke(
    GetFileAndFoldersServiceCommand command,
  ) async {
    isLoading.add(true);
    AppDatabase? db = DatabaseManager.instance.database;
    FileDesktopRepository fileRepo = FileDesktopRepository(db!);
    FolderDesktopRepository folderRepo = FolderDesktopRepository(db);

    // relativePath is what gets stored in the DB and used for repo queries.
    String relativePath = command.path;
    if (relativePath.length > 1 && relativePath.endsWith('/')) {
      relativePath = relativePath.substring(0, relativePath.length - 1);
    }

    // absolutePath is used for filesystem operations (scanner start).
    String absolutePath;

    const emailScanners = {
      AppConstants.scannerEmailOutlookPst,
      AppConstants.scannerEmailYahoo,
      AppConstants.scannerEmailGmail,
    };

    if (emailScanners.contains(command.collection.scanner)) {
      // Email collections use a computed extraction root; files are stored
      // relative to this root in the database.
      final storagePath = DatabaseManager.instance.storagePath;
      if (storagePath != null) {
        final extractionRoot = p.join(
          storagePath, 'files', 'email', command.collection.id,
        );
        // command.path is always a relative path (e.g. "" / "INBOX" / "INBOX/2022").
        // The only legacy case where it could be wrong is if an absolute path
        // that is NOT under the extraction root was stored (e.g. the old
        // email-address string). Reset to root only in that case.
        if (p.isAbsolute(command.path) && !command.path.startsWith(extractionRoot)) {
          relativePath = '';
        }
        // Build the absolute path for the scanner from the (possibly corrected) relativePath.
        absolutePath = relativePath.isEmpty
            ? extractionRoot
            : p.join(extractionRoot, relativePath);
      } else {
        absolutePath = FilePathResolver.absoluteFromPath(
            relativePath, command.collection);
      }
    } else {
      // Local/cloud collections: resolve absolute path from localCopyPath.
      absolutePath = FilePathResolver.absoluteFromPath(
          relativePath, command.collection);
      if (absolutePath.isEmpty) absolutePath = command.collection.path;
    }

    // Skip scanner if it's just a refresh-only or load-more request.
    if (!command.refreshOnly && command.offset == 0) {
      ScannerManager.getInstance()
          .getScanner(command.collection)
          ?.start(command.collection, absolutePath, false, false);
    }

    // Folders always load fully; only files paginate.
    final List<FileAsset> folders = command.offset == 0
        ? await folderRepo.getByParentPath(command.collection.id, relativePath)
        : [];

    final List<FileAsset> files = await fileRepo.getByParentPath(
      command.collection.id,
      relativePath,
      limit: command.pageSize,
      offset: command.offset,
    );

    final List<FileAsset> newItems = [...folders, ...files];

    if (command.offset == 0) {
      _currentItems = newItems;
    } else {
      _currentItems = [..._currentItems, ...newItems];
    }
    sink.add(_currentItems);

    isLoading.add(false);
    return newItems;
  }
}

class GetFileAndFoldersServiceCommand implements RxCommand {
  Collection collection;

  /// Loads all files and folders for `path`. `path` can be a `Folder.ID` or `null` for the root of the collection.
  String path;
  bool refreshOnly;

  /// Pagination offset for files (folders are always fully loaded on page 0).
  int offset;

  /// Number of files to fetch per page.
  int pageSize;

  GetFileAndFoldersServiceCommand(
    this.collection,
    this.path, {
    this.refreshOnly = false,
    this.offset = 0,
    this.pageSize = kFilesPageSize,
  });
}
