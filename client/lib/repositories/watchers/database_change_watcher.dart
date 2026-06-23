// ignore_for_file: unused_local_variable

import 'dart:async';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/files/services/utilities/exif_extractor.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_generator.dart';

class DatabaseChangeWatcher {
  AppDatabase database;

  //Utilities
  ThumbnailGenerator thumbnailGenerator = ThumbnailGenerator();
  ExifExtractor exifExtractor = ExifExtractor();

  DatabaseChangeWatcher(this.database);

  void start() {
    _initializeSyncWatchers();
  }

  void stop() {
    // stop query listeners
    collectionSubs?.cancel();
    fileSubs?.cancel();
    folderSubs?.cancel();
    emailSubs?.cancel();
  }

  final AppLogger logger = AppLogger(null);

  //class reference to keep change listeners running
  StreamSubscription<List<Collection>>? collectionSubs;
  StreamSubscription<List<Email>>? emailSubs;
  StreamSubscription<List<File>>? fileSubs;
  StreamSubscription<List<Folder>>? folderSubs;

  /// Start a realm change stream for each collection type
  void _initializeSyncWatchers() {
    // TODO: Re-implement these if needed
    // _watchCollections();
    // _watchFolders();
    // _watchFiles();
    // _watchEmails();
  }
}
