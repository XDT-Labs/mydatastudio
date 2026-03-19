import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/modules/files/files_constants.dart';
import 'package:flutter/services.dart';
import 'package:mydatatools/scanners/collection_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:logger/logger.dart';


class LocalFileIsolate extends CollectionScanner {
  RootIsolateToken? token;
  SendPort? loggerIsolatePort;
  SendPort? dbWriterIsolatePort;
  Isolate? isolate;
  AppLogger? logger;

  LocalFileIsolate(this.loggerIsolatePort, this.dbWriterIsolatePort) : super() {
    logger = AppLogger(loggerIsolatePort);
  }

  @override
  Future<int> start(Collection collection,
      String? path,
      recursive,
      bool force,) async {
    if (isScanning.value && !force) {
      return 0;
    }

    if (force) {
      stop();
    }

    isScanning.add(true);
    // A Stream that handles communication between isolates
    ReceivePort p = ReceivePort();
    RootIsolateToken? token = RootIsolateToken.instance;
    Map<String, dynamic> args = {
      'path': path,
      'recursive': recursive,
      'collectionId': collection.id,
    };

    //// Invoked the _scan() method in an isolate thread
    LocalFileIsolateWorker worker = LocalFileIsolateWorker(token!, p.sendPort, dbWriterIsolatePort!, loggerIsolatePort);
    isolate = await Isolate.spawn<Map<String, dynamic>>(worker._scan, args);
    isolate!.addOnExitListener(p.sendPort);

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
            case 'info': logger?.i('[LocalScan] $msg'); break;
            case 'error': logger?.e('[LocalScan] $msg', error: message['error'], stackTrace: message['stackTrace']); break;
            case 'warning': logger?.w('[LocalScan] $msg'); break;
            case 'debug': logger?.d('[LocalScan] $msg'); break;
            default: logger?.i('[LocalScan] $msg');
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
}



//// Method will run in Isolate
class LocalFileIsolateWorker{

  RootIsolateToken token;
  SendPort receiverPort;
  SendPort dbWriterPort;
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
  LocalFileIsolateWorker(this.token, this.receiverPort, this.dbWriterPort, this.loggerPort){
    // Ensure the background binary messenger is initialized so plugins/platform channels work
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }

  // start scanning
  void _scan(Map<String, dynamic> args) async {
    Logger.level = Level.debug;
    logger = AppLogger(loggerPort);

    String path = args['path'];
    // Normalize path: Remove trailing slash if it exists (unless it's just '/')
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    bool recursive = args['recursive'];
    String collectionId = args['collectionId'];

    // start scanner on first directory
    logger?.i('Scanning: $path');
    DateTime scanStartTime = DateTime.now();

    var fileCount = await _scanDir(
      collectionId,
      path,
      recursive,
      scanStartTime,
    );

    // Final cleanup and sync
    final ReceivePort syncPort = ReceivePort();
    dbWriterPort.send({
      'type': 'cleanup_deleted',
      'collectionId': collectionId,
      'path': path,
      'scanStartTime': scanStartTime,
      'recursive': recursive,
      'replyTo': syncPort.sendPort, // Await this to ensure DB is updated before isolate exits
    });

    // Wait for the DB writer to finish the cleanup task
    await syncPort.first;
    syncPort.close();

    // return file count
    Isolate.exit(receiverPort, fileCount);
  }

  Future<int> _scanDir(
    String collectionId,
    String path,
    recursive,
    DateTime scanStartTime,
    [List<File>? currentBatch]
  ) async {
    int count = 0;
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
      return 0;
    }

    for (var asset in dirList) {
      if (asset is io.File) {
        count++;
        //save file
        File? file = _validateFile(collectionId, asset, scanStartTime);
        if( file != null ) {
          logger.i('Found file: ${file.path}');
          fileBatch.add(file);
          if (fileBatch.length >= 100) {
            dbWriterPort.send({
              'type': 'batch_file',
              'files': List.from(fileBatch)
            });
            fileBatch.clear();
          }
        }
      } else if (asset is io.Directory) {
        //send status message back
        logger.s('Scanning: ${asset.path}');
        //save directory
        Folder? folder = _validateFolder(collectionId, asset, scanStartTime);
        if( folder != null ) {
          logger.i('Found folder: ${folder.path}');
          dbWriterPort.send({
            'type': 'folder',
            'folder': folder
          });

          try {
            if (recursive) {
              int fileCount = await _scanDir(
                collectionId,
                folder.path, // Use normalized path
                recursive,
                scanStartTime,
                fileBatch,
              );
              count += fileCount;
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
      dbWriterPort.send({
        'type': 'batch_file',
        'files': List.from(fileBatch)
      });
      fileBatch.clear();
    }

    return Future(() => count);
  }

  //

  /// Validate directories against the know paths we want to skip.
  /// Convert dart.io to a local model object
  Folder? _validateFolder(
    String collectionId_,
    io.Directory dir_,
    DateTime scanStartTime,
  ) {
    String path = dir_.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    String name = p.basename(path);

    //skip any hidden or system folders
    bool hidden = name.startsWith('.');
    bool skipFolder = skipFolderRegex.hasMatch('/$name/');
    
    if( hidden || skipFolder ){
      logger?.i('Skipping folder (hidden=$hidden, skipFolder=$skipFolder): $path');
      return null;
    }

    String parentPath = p.dirname(path);

    return Folder(
        id: '$collectionId_:$path',
        name: name,
        path: path,
        parent: parentPath,
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        lastScannedDate: scanStartTime,
        collectionId: collectionId_,
    );
  }

  /// Validate directories against the know paths we want to skip.
  /// Convert dart.io to a local model object
  File? _validateFile(
    String collectionId_,
    io.File file_,
    DateTime scanStartTime,
  ) {
    String path = file_.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    String name = p.basename(path);

    //skip any files in a hidden or system folder
    bool hidden = name.startsWith('.');
    // We don't usually skip files based on skipFolderRegex, but the original code did.
    // However, it checked the full path. Let's keep it checking the full path but more safely,
    // or just check the parent's skip status.
    // The original code was: bool skipFolder = skipFolderRegex.hasMatch(file_.path);
    // If a parent folder was skipped, this file wouldn't even be reached in _scanDir.
    // So checking it here might be redundant if it's about folder names.
    bool skipFolder = skipFolderRegex.hasMatch(file_.path); 

    if( hidden || skipFolder ){
      logger?.i('Skipping file (hidden=$hidden, skipFolder=$skipFolder): $path');
      return null;
    }


    //Check if it exists, skip it if it does
    DateTime lmDate = file_.lastModifiedSync();
    //todo: add date check to if statement
    String parentPath = p.dirname(path);

    return File(
      id: '$collectionId_:$path',
      collectionId: collectionId_,
      name: name,
      path: path,
      parent: parentPath,
      dateCreated: lmDate,
      dateLastModified: lmDate,
      lastScannedDate: scanStartTime,
      isDeleted: false,
      size: file_.lengthSync(),
      contentType: getMimeType(name),
    );
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
