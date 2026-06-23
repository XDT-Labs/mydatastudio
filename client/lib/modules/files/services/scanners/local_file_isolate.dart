import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/batch_file_upsert_service.dart';
import 'package:mydatastudio/modules/files/services/cleanup_deleted_files_service.dart';
import 'package:mydatastudio/modules/files/services/folder_upsert_service.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';
import 'package:mydatastudio/modules/files/services/scanners/scanner_path_helper.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_generator.dart';

/// [LocalFileIsolate] is a collection scanner responsible for indexing files
/// on the local filesystem. It uses a background Dart isolate to crawl
/// directories, extract metadata (EXIF, thumbnails), and update the database.
///
/// Synchronization Rules:
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
class LocalFileIsolate extends CollectionScanner {
  RootIsolateToken? token;
  SendPort? loggerIsolatePort;
  String? storagePath;
  String? dbName;
  Isolate? isolate;
  AppLogger? logger;

  LocalFileIsolate(this.loggerIsolatePort, {this.storagePath, this.dbName})
    : super() {
    logger = AppLogger(loggerIsolatePort);
  }

  /// Starts the local file scanning process.
  ///
  /// [collection] The local collection to scan.
  /// [path] Mode selector:
  ///   - If NULL: **Full Sync**. Exhaustively traverses the entire collection root.
  ///   - If NOT NULL: **Targeted Scan**. Focuses ONLY on the specified directory
  ///     path for immediate results during navigation.
  /// [recursive] Whether to scan subdirectories.
  /// [force] If false, returns 0 immediately (Rule 2). If true, triggers sync.
  @override
  Future<int> start(
    Collection collection,
    String? path,
    recursive,
    bool force,
  ) async {
    if (!force) {
      logger?.i("Registration-only mode: skipping scan for ${collection.name}");
      return 0;
    }

    if (force) {
      stop();
    }

    isScanning.add(true);
    // A Stream that handles communication between isolates
    ReceivePort p = ReceivePort();
    RootIsolateToken? token = RootIsolateToken.instance;
    final rootPath = collection.localCopyPath ?? collection.path;
    Map<String, dynamic> args = {
      'path': path ?? rootPath,
      'rootPath': rootPath,
      'recursive': recursive,
      'force': force,
      'collectionId': collection.id,
      'lastScanDate': collection.lastScanDate?.toIso8601String(),
      'llmServiceUrl': MainApp.llmServiceUrl.valueOrNull,
    };

    //// Invoked the _scan() method in an isolate thread
    LocalFileIsolateWorker worker = LocalFileIsolateWorker(
      token,
      p.sendPort,
      storagePath!,
      dbName!,
      loggerIsolatePort,
    );
    logger?.i('Spawning local file scanner isolate for $path');
    try {
      isolate = await spawnIsolate(worker._scan, args);
    } catch (e) {
      logger?.e('Failed to spawn local file scanner isolate: $e');
      return 0;
    }
    isolate?.addOnExitListener(p.sendPort);

    await for (var message in p) {
      if (message == null) {
        // Isolate exited
        break;
      }
      if (message is SendPort) {
        // connected (heartbeat or discovery)
        logger?.s(message);
      } else if (message is Map) {
        final type = message['type'];
        final msg = message['message'];

        if (type == 'log') {
          final level = message['level'] as String;
          switch (level) {
            case 'info':
              logger?.i('[LocalScan] $msg');
              break;
            case 'error':
              logger?.e(
                '[LocalScan] $msg',
                error: message['error'],
                stackTrace: message['stackTrace'],
              );
              break;
            case 'warning':
              logger?.w('[LocalScan] $msg');
              break;
            case 'debug':
              logger?.d('[LocalScan] $msg');
              break;
            default:
              logger?.i('[LocalScan] $msg');
          }
        } else if (type == 'status') {
          logger?.s(msg);
        }
      }
    }

    isScanning.add(false);
    return Future(() => 0);
  }

  @override
  void stop() async {
    //clear any isolates
    if (isolate != null) {
      isolate!.kill(priority: Isolate.beforeNextEvent);
      logger?.w('Killed local file scanner');
    }
  }

  /// Overridable for testing to avoid real isolate spawning
  Future<Isolate?> spawnIsolate(
    void Function(Map<String, dynamic>) entryPoint,
    Map<String, dynamic> args,
  ) async {
    return await Isolate.spawn<Map<String, dynamic>>(entryPoint, args);
  }
}

//// Method will run in Isolate
class LocalFileIsolateWorker {
  RootIsolateToken? token;
  SendPort receiverPort;
  String storagePath;
  String dbName;
  SendPort? loggerPort;
  AppLogger? logger;

  // TODO: add this list to a global config / UI page
  final skipFolderRegex = RegExp(
    r'/(go|node_modules|Pods|\.git)(/|$)',
    multiLine: false,
    caseSensitive: true,
    unicode: true,
  );

  //constructor
  LocalFileIsolateWorker(
    this.token,
    this.receiverPort,
    this.storagePath,
    this.dbName,
    this.loggerPort,
  ) {
    // Ensure the background binary messenger is initialized so plugins/platform channels work
    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token!);
    }
  }

  // start scanning
  void _scan(Map<String, dynamic> args) async {
    logger = AppLogger(loggerPort);

    final appDb = await AppDatabase.create(null, storagePath, dbName);

    String path = args['path'];
    // Normalize path: Remove trailing slash if it exists (unless it's just '/')
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    // rootPath is the absolute collection root used to compute relative paths.
    String rootPath = args['rootPath'] as String? ?? path;
    if (rootPath.length > 1 && rootPath.endsWith('/')) {
      rootPath = rootPath.substring(0, rootPath.length - 1);
    }
    bool recursive = args['recursive'];
    bool force = args['force'] ?? false;
    String collectionId = args['collectionId'];
    String? llmServiceUrl = args['llmServiceUrl'];

    // Stats for logging
    int cacheHits = 0;
    int generatedThumbnails = 0;
    int totalFiles = 0;

    logger?.i('LocalScan: Starting scan for $collectionId (force=$force)');

    // Fetch existing file metadata to avoid redundant processing
    final Map<String, File> metadataCache = {};
    try {
      final List<File> files = await FileDesktopRepository(
        appDb,
      ).getScanMetadata(collectionId);
      for (final f in files) {
        metadataCache[f.id] = f;
      }
      logger?.i(
        'LocalScan: Loaded ${metadataCache.length} existing file records for caching',
      );
    } catch (e) {
      logger?.e('LocalScan: Failed to fetch metadata cache: $e');
    }

    // start scanner on first directory
    logger?.i('Scanning: $path');
    DateTime scanStartTime = DateTime.now();

    var results = await _scanDir(
      appDb,
      collectionId,
      path,
      rootPath,
      recursive,
      scanStartTime,
      metadataCache: metadataCache,
      llmServiceUrl: llmServiceUrl,
    );
    int fileCount = results['count'] ?? 0;
    cacheHits = results['cacheHits'] ?? 0;
    generatedThumbnails = results['generatedThumbnails'] ?? 0;
    totalFiles = results['total'] ?? 0;

    logger?.i(
      'LocalScan: Scan finished. Found $fileCount items. Stats: Total=$totalFiles, CacheHits=$cacheHits, NewThumbs=$generatedThumbnails',
    );

    // Final cleanup — mark anything not seen this scan as deleted.
    final cleanupRelPath = p.relative(path, from: rootPath);
    await CleanupDeletedFilesService.instance.invoke(
      CleanupDeletedFilesServiceCommand(
        collectionId,
        cleanupRelPath == '.' ? '' : cleanupRelPath,
        scanStartTime,
        appDb,
        recursive: recursive,
      ),
    );

    // Update collection lastScanDate and status
    final colRepo = CollectionRepository(appDb);
    final col = await colRepo.collectionById(collectionId);
    if (col != null) {
      col.scanStatus = 'idle';
      col.lastScanDate = scanStartTime;
      await colRepo.updateCollection(col);
    }

    // return file count
    print('Worker: Exiting isolate with count $fileCount');
    Isolate.exit(receiverPort, fileCount);
  }

  Future<Map<String, int>> _scanDir(
    AppDatabase appDb,
    String collectionId,
    String path, // absolute path used for filesystem operations
    String rootPath, // absolute collection root for computing relative paths
    recursive,
    DateTime scanStartTime, {
    Map<String, File>? metadataCache,
    List<File>? currentBatch,
    String? llmServiceUrl,
  }) async {
    int count = 0;
    int cacheHits = 0;
    int generatedThumbnails = 0;
    int totalFiles = 0;

    List<File> fileBatch = currentBatch ?? [];
    AppLogger logger = AppLogger(loggerPort);

    var dir = io.Directory(path);
    logger.s('Scanning ${dir.path}');

    var dirList = [];
    try {
      dirList = dir.listSync(recursive: false, followLinks: false);
      logger.i('Found ${dirList.length} items in ${dir.path}');
    } catch (e) {
      logger.e('Failed to list directory ${dir.path}: $e');
      return {'count': 0, 'cacheHits': 0, 'generatedThumbnails': 0, 'total': 0};
    }

    for (var asset in dirList) {
      if (asset is io.File) {
        count++;
        // Save file record with caching and thumbnail generation
        final validation = await _validateFile(
          collectionId,
          asset,
          rootPath,
          scanStartTime,
          metadataCache: metadataCache,
          llmServiceUrl: llmServiceUrl,
        );

        final file = validation['file'] as File?;
        if (validation['isCacheHit'] == true) cacheHits++;
        if (validation['isGenerated'] == true) generatedThumbnails++;

        if (file != null) {
          fileBatch.add(file);
          if (fileBatch.length >= 100) {
            logger.i('Found ${fileBatch.length} files, saving batch');
            await BatchFileUpsertService.instance.invoke(
              BatchFileUpsertServiceCommand(List<File>.from(fileBatch), appDb),
            );
            fileBatch.clear();
          }
        }
      } else if (asset is io.Directory) {
        //send status message back
        logger.s('Scanning: ${asset.path}');
        //save directory
        Folder? folder = _validateFolder(
          collectionId,
          asset,
          rootPath,
          scanStartTime,
        );
        if (folder != null) {
          logger.i('Found folder: ${folder.path}');
          await FolderUpsertService.instance.invoke(
            FolderUpsertServiceCommand(folder, appDb),
          );

          try {
            if (recursive) {
              final subResults = await _scanDir(
                appDb,
                collectionId,
                asset.path, // absolute path for filesystem traversal
                rootPath,
                recursive,
                scanStartTime,
                metadataCache: metadataCache,
                currentBatch: fileBatch,
                llmServiceUrl: llmServiceUrl,
              );
              count += subResults['count'] ?? 0;
              cacheHits += subResults['cacheHits'] ?? 0;
              generatedThumbnails += subResults['generatedThumbnails'] ?? 0;
              totalFiles += subResults['total'] ?? 0;
            }
          } catch (err) {
            logger.w(err);
          }
        }
      } else {
        logger.w("unknown type");
      }
    }

    if (currentBatch == null && fileBatch.isNotEmpty) {
      logger.i('Found ${fileBatch.length} files, saving final batch');
      await BatchFileUpsertService.instance.invoke(
        BatchFileUpsertServiceCommand(List<File>.from(fileBatch), appDb),
      );
      fileBatch.clear();
    }

    return {
      'count': count,
      'cacheHits': cacheHits,
      'generatedThumbnails': generatedThumbnails,
      'total': totalFiles,
    };
  }

  //

  /// Validate directories. Compute relative path for storage.
  Folder? _validateFolder(
    String collectionId_,
    io.Directory dir_,
    String rootPath,
    DateTime scanStartTime,
  ) {
    String absPath = dir_.path;
    if (absPath.length > 1 && absPath.endsWith('/')) {
      absPath = absPath.substring(0, absPath.length - 1);
    }
    String name = p.basename(absPath);

    //skip any hidden or system folders
    bool hidden = name.startsWith('.');
    bool skipFolder = skipFolderRegex.hasMatch('/$name/');

    if (hidden || skipFolder) {
      logger?.i(
        'Skipping folder (hidden=$hidden, skipFolder=$skipFolder): $absPath',
      );
      return null;
    }

    // Compute relative path for storage via the shared helper so this logic
    // is unit-tested independently of the file system.
    final relPath = ScannerPathHelper.relativePath(
      absPath,
      rootPath,
      isFolder: true,
    );
    final relParent = ScannerPathHelper.relativeParent(absPath, rootPath);

    return Folder(
      id: ScannerPathHelper.buildId(collectionId_, relPath),
      name: name,
      path: relPath,
      parent: relParent,
      dateCreated: DateTime.now(),
      dateLastModified: DateTime.now(),
      lastScannedDate: scanStartTime,
      collectionId: collectionId_,
    );
  }

  /// Validate files. Compute relative path for storage.
  Future<Map<String, dynamic>> _validateFile(
    String collectionId_,
    io.File file_,
    String rootPath,
    DateTime scanStartTime, {
    Map<String, File>? metadataCache,
    String? llmServiceUrl,
  }) async {
    // Return both the file and hit/gen status for statistics
    Map<String, dynamic> result = {
      'file': null,
      'isCacheHit': false,
      'isGenerated': false,
    };

    String absPath = file_.path;
    if (absPath.length > 1 && absPath.endsWith('/')) {
      absPath = absPath.substring(0, absPath.length - 1);
    }
    String name = p.basename(absPath);

    bool hidden = name.startsWith('.');
    bool skipFolder = skipFolderRegex.hasMatch(file_.path);

    if (hidden || skipFolder) {
      logger?.i(
        'Skipping file (hidden=$hidden, skipFolder=$skipFolder): $absPath',
      );
      return result;
    }

    DateTime lmDate = file_.lastModifiedSync();

    // Compute relative path for storage via the shared helper.
    final relPath = ScannerPathHelper.relativePath(absPath, rootPath);
    final relParent = ScannerPathHelper.relativeParent(absPath, rootPath);
    final fileId = ScannerPathHelper.buildId(collectionId_, relPath);

    // Metadata Check:
    // If the file is already in our DB and hasn't changed, reuse the record and its thumbnail.
    if (metadataCache != null && metadataCache.containsKey(fileId)) {
      final cached = metadataCache[fileId]!;

      // Precision fix: Truncate both to seconds before comparing.
      // SQLite stores DateTime as unix seconds, losing milliseconds.
      final bool mtimeMatches =
          (cached.dateLastModified.millisecondsSinceEpoch ~/ 1000) ==
          (lmDate.millisecondsSinceEpoch ~/ 1000);

      final bool hasThumbnail = cached.thumbnail != null;
      final bool isImage = getMimeType(name) == FilesConstants.mimeTypeImage;

      if (mtimeMatches && (!isImage || hasThumbnail)) {
        // Return a copy with the new scan time to prevent deletion
        result['isCacheHit'] = true;
        result['file'] = File(
          id: cached.id,
          name: cached.name,
          path: cached.path,
          parent: cached.parent,
          dateCreated: cached.dateCreated,
          dateLastModified: cached.dateLastModified,
          lastScannedDate: scanStartTime,
          collectionId: cached.collectionId,
          contentType: cached.contentType,
          size: cached.size,
          isDeleted: false,
          thumbnail: cached.thumbnail,
          downloadUrl: cached.downloadUrl,
          emailId: cached.emailId,
          latitude: cached.latitude,
          longitude: cached.longitude,
          localPath: cached.localPath,
        );
        return result;
      }
    }

    // Generate thumbnail if it's an image
    String? thumbnail;
    final mimeType = getMimeType(name);
    if (mimeType == FilesConstants.mimeTypeImage) {
      try {
        // Thumbnail generation can be slow, but this is a background isolate.
        // We use the absolute path for generation.
        logger?.i('LocalScanner: Generating thumbnail for $absPath');
        thumbnail = await ThumbnailGenerator().pathImageToBase64(
          absPath,
          mimeType,
          llmServiceUrl: llmServiceUrl,
        );
        if (thumbnail != null) {
          result['isGenerated'] = true;
        }
      } catch (e) {
        logger?.e('LocalScanner: Error generating thumbnail for $absPath: $e');
      }
    }

    result['file'] = File(
      id: fileId,
      collectionId: collectionId_,
      name: name,
      path: relPath,
      parent: relParent,
      dateCreated: lmDate,
      dateLastModified: lmDate,
      lastScannedDate: scanStartTime,
      isDeleted: false,
      size: file_.lengthSync(),
      contentType: mimeType,
      thumbnail: thumbnail,
    );

    return result;
  }

  String getMimeType(String name) {
    String extension = name.split(".").last;
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'png':
      case 'tif':
      case 'psd':
      case 'nef':
        return FilesConstants.mimeTypeImage;
      case 'pdf':
        return FilesConstants.mimeTypePdf;
      case 'mp4':
      case 'm4v':
      case 'mpeg':
      case 'mov':
        return FilesConstants.mimeTypeMovie;
      case 'mp3':
        return FilesConstants.mimeTypeMusic;
      default:
        return FilesConstants.mimeTypeUnKnown;
    }
  }
}

/** TODO map extra types and move to helper class
    {
    {".3gp",    "video/3gpp"},
    {".torrent","application/x-bittorrent"},
    {".kml",    "application/vnd.google-earth.kml+xml"},
    {".gpx",    "application/gpx+xml"},
    {".csv",    "application/vnd.ms-excel"},
    {".apk",    "application/vnd.android.package-archive"},
    {".asf",    "video/x-ms-asf"},
    {".avi",    "video/x-msvideo"},
    {".bin",    "application/octet-stream"},
    {".bmp",    "image/bmp"},
    {".c",      "text/plain"},
    {".class",  "application/octet-stream"},
    {".conf",   "text/plain"},
    {".cpp",    "text/plain"},
    {".doc",    "application/msword"},
    {".docx",   "application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
    {".xls",    "application/vnd.ms-excel"},
    {".xlsx",   "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
    {".exe",    "application/octet-stream"},
    {".gif",    "image/gif"},
    {".gtar",   "application/x-gtar"},
    {".gz",     "application/x-gzip"},
    {".h",      "text/plain"},
    {".htm",    "text/html"},
    {".html",   "text/html"},
    {".jar",    "application/java-archive"},
    {".java",   "text/plain"},
    {".jpeg",   "image/jpeg"},
    {".jpg",    "image/jpeg"},
    {".js",     "application/x-javascript"},
    {".log",    "text/plain"},
    {".m3u",    "audio/x-mpegurl"},
    {".m4a",    "audio/mp4a-latm"},
    {".m4b",    "audio/mp4a-latm"},
    {".m4p",    "audio/mp4a-latm"},
    {".m4u",    "video/vnd.mpegurl"},
    {".m4v",    "video/x-m4v"},
    {".mov",    "video/quicktime"},
    {".mp2",    "audio/x-mpeg"},
    {".mp3",    "audio/x-mpeg"},
   
    {".mpc",    "application/vnd.mpohun.certificate"},
    {".mpe",    "video/mpeg"},
   
    {".mpg",    "video/mpeg"},
    {".mpg4",   "video/mp4"},
    {".mpga",   "audio/mpeg"},
    {".msg",    "application/vnd.ms-outlook"},
    {".ogg",    "audio/ogg"},
    {".pdf",    "application/pdf"},
    {".png",    "image/png"},
    {".pps",    "application/vnd.ms-powerpoint"},
    {".ppt",    "application/vnd.ms-powerpoint"},
    {".pptx",   "application/vnd.openxmlformats-officedocument.presentationml.presentation"},
    {".prop",   "text/plain"},
    {".rc",     "text/plain"},
    {".rmvb",   "audio/x-pn-realaudio"},
    {".rtf",    "application/rtf"},
    {".sh",     "text/plain"},
    {".tar",    "application/x-tar"},
    {".tgz",    "application/x-compressed"},
    {".txt",    "text/plain"},
    {".wav",    "audio/x-wav"},
    {".wma",    "audio/x-ms-wma"},
    {".wmv",    "audio/x-ms-wmv"},
    {".wps",    "application/vnd.ms-works"},
    {".xml",    "text/plain"},
    {".z",      "application/x-compress"},
    {".zip",    "application/x-zip-compressed"},
}
 */
