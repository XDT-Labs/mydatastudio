import 'dart:async';
import 'package:rxdart/rxdart.dart' show Rx;
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file_asset.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/files/services/repositories/folder_repository.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:path/path.dart' as p;

/// Number of files fetched per page.
const int kFilesPageSize = 200;

class GetFileAndFoldersService
    extends RxService<GetFileAndFoldersServiceCommand, List<FileAsset>> {
  static final GetFileAndFoldersService _singleton = GetFileAndFoldersService();
  static GetFileAndFoldersService get instance => _singleton;
  AppLogger logger = AppLogger(null);

  /// Tracks the subscription to the database stream.
  StreamSubscription<List<FileAsset>>? _currentSubscription;

  /// Tracks the accumulated pages so load-more can append without reading
  /// the sink (which is typed as `Subject<R>` and has no valueOrNull).
  List<FileAsset> _currentItems = [];

  @override
  void reset() {
    _currentSubscription?.cancel();
    _currentSubscription = null;
    super.reset();
  }

  @override
  Future<List<FileAsset>> invoke(
    GetFileAndFoldersServiceCommand command,
  ) async {
    isLoading.add(true);

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
      final storagePath = DatabaseManager.instance.storagePath;
      if (storagePath != null) {
        final extractionRoot = p.join(
          storagePath,
          'files',
          'email',
          command.collection.id,
        );
        if (p.isAbsolute(command.path) &&
            !command.path.startsWith(extractionRoot)) {
          relativePath = '';
        }
        absolutePath =
            relativePath.isEmpty
                ? extractionRoot
                : p.join(extractionRoot, relativePath);
      } else {
        absolutePath = FilePathResolver.absoluteFromPath(
          relativePath,
          command.collection,
        );
      }
    } else {
      absolutePath = FilePathResolver.absoluteFromPath(
        relativePath,
        command.collection,
      );
      if (absolutePath.isEmpty) absolutePath = command.collection.path;
    }

    // ── 1. QUERY DB FIRST — show cached results immediately ──────────
    try {
      final AppDatabase db = DatabaseManager.instance.database!;
      final FileDesktopRepository fileRepo = FileDesktopRepository(db);
      final FolderDesktopRepository folderRepo = FolderDesktopRepository(db);

      final List<FileAsset> folders =
          command.offset == 0
              ? await folderRepo.getByParentPath(
                command.collection.id,
                relativePath,
              )
              : [];

      final List<FileAsset> files = await fileRepo.getByParentPath(
        command.collection.id,
        relativePath,
        limit: command.pageSize,
        offset: command.offset,
      );

      final List<FileAsset> newItems = [...folders, ...files];
      print(
        'GetFileAndFoldersService.invoke: query returned ${folders.length} folders and ${files.length} files (total: ${newItems.length}) for path "${command.path}" in db "${db.path}"',
      );

      if (command.offset == 0) {
        _currentItems = newItems;
      } else {
        _currentItems = [..._currentItems, ...newItems];
      }
      sink.add(_currentItems);

      // Cancel previous stream subscription
      await _currentSubscription?.cancel();

      // Start reactive stream query for both folders and files
      final folderStream = db.stream(
        "SELECT * FROM folders WHERE collection_id = ? AND parent = ? ORDER BY name",
        [command.collection.id, relativePath],
      ).map((rows) => rows.map((r) => Folder.fromDbMap(r)).toList());

      final fileStream = db.stream(
        "SELECT * FROM files WHERE collection_id = ? AND parent = ? AND is_deleted = 0 ORDER BY name LIMIT ?",
        [
          command.collection.id,
          relativePath,
          command.offset + command.pageSize,
        ],
      ).map((rows) => rows.map((r) => File.fromDbMap(r)).toList());

      _currentSubscription = Rx.combineLatest2<List<Folder>, List<File>, List<FileAsset>>(
        folderStream,
        fileStream,
        (fldrs, fls) => [...fldrs, ...fls],
      ).listen((updatedItems) {
        _currentItems = updatedItems;
        sink.add(updatedItems);
      });

      // ── 2. THEN trigger scanner in background ────────────────────
      // Fire-and-forget: the scanner writes to the DB directly.
      // When isScanning transitions false→true→false the page auto-refreshes.
      if (!command.refreshOnly && command.offset == 0) {
        ScannerManager.getInstance()
            .getScannerAsync(command.collection)
            .then(
              (scanner) =>
                  scanner.start(command.collection, absolutePath, false, false),
            );
      }

      isLoading.add(false);
      return newItems;
    } catch (e, stack) {
      logger.e(
        'GetFileAndFoldersService.invoke failed: $e',
        error: e,
        stackTrace: stack,
      );
      isLoading.add(false);
      return _currentItems;
    }
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
