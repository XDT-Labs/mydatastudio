import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:mydatatools/modules/files/services/repositories/folder_repository.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/services/rx_service.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:path/path.dart' as p;

/// Number of files fetched per page.
const int kFilesPageSize = 200;

class GetFileAndFoldersService
    extends RxService<GetFileAndFoldersServiceCommand, List<FileAsset>> {
  static final GetFileAndFoldersService _singleton =
      GetFileAndFoldersService();
  static get instance => _singleton;
  AppLogger logger = AppLogger(null);

  /// Tracks the accumulated pages so load-more can append without reading
  /// the sink (which is typed as Subject<R> and has no valueOrNull).
  List<FileAsset> _currentItems = [];

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

    // For email collections the nominal collection.path is not a browsable
    // directory (it could be a .pst file path or an email address like
    // mikenimer@yahoo.com). Resolve to the extraction root where attachments
    // are stored so the file module can navigate the folder/year tree.
    const _emailScanners = {
      AppConstants.scannerEmailOutlookPst,
      AppConstants.scannerEmailYahoo,
      AppConstants.scannerEmailGmail,
    };
    if (_emailScanners.contains(command.collection.scanner)) {
      final storagePath = DatabaseManager.instance.storagePath;
      if (storagePath != null) {
        final extractionRoot = p.join(storagePath, 'files', 'email', command.collection.id);
        // Only remap when the caller is still pointing at the raw collection path
        // (i.e. not when the user has already navigated deeper inside the tree).
        if (!path.startsWith(extractionRoot)) {
          path = extractionRoot;
        }
      }
    }

    // Skip scanner if it's just a refresh-only or load-more request.
    // The scan runs in a background isolate — we fire it without awaiting so
    // the DB query and UI update happen immediately.
    if (!command.refreshOnly && command.offset == 0) {
      ScannerManager.getInstance()
          .getScanner(command.collection)
          ?.start(command.collection, path, false, false);
    }

    // Folders always load fully (rarely > 500 per dir); only files paginate.
    final List<FileAsset> folders = command.offset == 0
        ? await folderRepo.getByParentPath(command.collection.id, path)
        : [];

    final List<FileAsset> files = await fileRepo.getByParentPath(
      command.collection.id,
      path,
      limit: command.pageSize,
      offset: command.offset,
    );

    final List<FileAsset> newItems = [...folders, ...files];

    if (command.offset == 0) {
      // First page — replace the current list entirely.
      _currentItems = newItems;
    } else {
      // Load-more — append to the existing list.
      _currentItems = [..._currentItems, ...newItems];
    }
    sink.add(_currentItems);

    isLoading.add(false);
    return newItems;
  }
}

class GetFileAndFoldersServiceCommand implements RxCommand {
  Collection collection;
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


