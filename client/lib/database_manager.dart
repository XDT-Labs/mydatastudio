import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Table;
import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/repositories/database_repository.dart';
import 'package:mydatatools/repositories/db_isolate_writer.dart';
import 'package:path/path.dart' as p;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:mydatatools/models/tables/album.dart';
import 'package:mydatatools/models/tables/app.dart';
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/converters/string_array_convertor.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:uuid/uuid.dart';

part 'database_manager.g.dart';

class DatabaseManager {
  static final DatabaseManager _singleton = DatabaseManager._();

  /// Singleton instance of [DatabaseManager]
  static DatabaseManager get instance => _singleton;

  /// Notifies listeners when the database initialization is complete
  static ValueNotifier<bool> isInitializedNotifier = ValueNotifier(false);

  /// Flag to determine if an in-memory database should be used (for testing)
  bool useMemoryDb = false;
  AppDatabase? appDatabase;
  DbIsolateWriterClient? _writerIsolateClient;
  SendPort? _writerPort;
  DatabaseRepository? _repository;
  final AppLogger logger = AppLogger(null);

  DatabaseManager._();

  /// Returns the [DatabaseRepository] instance
  DatabaseRepository? get repository {
    return _repository;
  }

  /// Returns the [AppDatabase] instance
  AppDatabase? get database {
    return appDatabase;
  }

  Future<String> _getConfigPath() async {
    var supportPath = await getApplicationSupportDirectory();
    MainApp.supportDirectory.add(supportPath);

    // Look for config file with user selected path for DB and Files
    io.File file = io.File(
      p.join(supportPath.path, AppConstants.configFileName),
    );
    return file.absolute.path;
  }

  /// Checks if the database configuration file exists
  Future<bool> isDatabaseConfigured() async {
    // Look for config file with user selected path for DB and Files
    io.File file = io.File(await _getConfigPath());
    return file.existsSync();
  }

  /// Initializes the database, repository, writer isolate, and scanners
  Future<AppDatabase> initializeDatabase() async {
    io.File file = io.File(await _getConfigPath());
    var config = jsonDecode(file.readAsStringSync());
    String path = config['path'];

    // start database
    appDatabase = await _openDatabase(path);

    // start database repository
    _repository = DatabaseRepository(appDatabase!);

    // start writer isolate
    await _startWriterIsolate(appDatabase!, path);

    // start scanners
    await _startScanners();

    isInitializedNotifier.value = true;
    return appDatabase!;
  }

  Future<AppDatabase> _openDatabase(String storagePath) async {
    try {
      if (this.database != null) {
        return this.database!;
      }

      //make sure root dir exists
      io.Directory(storagePath).createSync(recursive: true);
      //make sure data, files, and keys sub dirs have been created
      var dbDir = io.Directory(p.join(storagePath, 'data'));
      io.Directory(dbDir.path).createSync(recursive: true);
      var keyDir = io.Directory(p.join(storagePath, 'keys'));
      io.Directory(keyDir.path).createSync(recursive: true);
      var fileDir = io.Directory(p.join(storagePath, 'files'));
      io.Directory(fileDir.path).createSync(recursive: true);

      //on app startup, start db.
      AppDatabase database = AppDatabase(
        null,
        storagePath,
        AppConstants.dbName,
        useMemoryDb,
      );
      logger.i("DB Started | schema version=${database.schemaVersion}");

      return database;
    } catch (err) {
      //unknown error
      logger.e(err);
      throw Exception(err);
    }
  }

  Future<void> _startWriterIsolate(
    AppDatabase database,
    String storagePath,
  ) async {
    _writerIsolateClient = DbIsolateWriterClient();
    await _writerIsolateClient!.start(
      storagePath,
      AppConstants.dbName,
      useMemoryDb: false,
    );
    _writerPort = _writerIsolateClient!.getSendPort();
  }

  /// Returns the [SendPort] for the writer isolate
  Future<SendPort> get writerPort async {
    if (_writerPort == null) {
      throw Exception(
        "Unkown error initializing Database and/or writer isolate",
      );
    }
    return Future(() => _writerPort!);
  }

  /// Stop helper to be called from app shell
  /// Stops the database writer isolate
  Future<void> stopDbWriterIsolate() async {
    try {
      if (_writerIsolateClient != null) {
        await _writerIsolateClient!.stop();
        _writerIsolateClient = null;
      }
    } catch (_) {}
  }

  Future<void> _startScanners() async {
    ScannerManager sm = ScannerManager(appDatabase!);
    MainApp.scannerManager = sm;
    sm.startScanners();
  }
}

@DriftDatabase(
  tables: [Apps, AppUsers, Collections, Emails, Files, Folders, Albums],
)
class AppDatabase extends _$AppDatabase {
  final AppLogger logger = AppLogger(null);

  AppDatabase([
    QueryExecutor? executor,
    String? path,
    String? name,
    bool useMemoryDb = false,
  ]) : super(executor ?? _openConnection(path, name, useMemoryDb));

  String? path;
  String? name;

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        logger.i("Creating all Tables");
        await m.createAll();
        logger.i("Load initial data");
        await _loadInitialData(m);
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          logger.i(
            "Upgrade to v2: Adding last_scanned_date to Files and Folders",
          );
          await m.addColumn(files, files.lastScannedDate);
          await m.addColumn(folders, folders.lastScannedDate);
        }
        if (from < 3) {
          logger.i(
            "Upgrade to v3: Adding download_url to Files and Folders, thumbnail to Folders",
          );
          await m.addColumn(files, files.downloadUrl);
          await m.addColumn(folders, folders.thumbnail);
          await m.addColumn(folders, folders.downloadUrl);
        }
        //continue
      },
    );
  }

  /// Make sure each app is in database
  Future<int> _loadInitialData(Migrator m) async {
    try {
      int appsAdded = 0;
      //Load initial data
      TableInfo<Table, dynamic>? appsTable = m.database.allTables
          .firstWhereOrNull((e) => e.actualTableName == 'apps');
      //List<dynamic> apps = await m.database.select(appsTable!).get();
      //apps
      await m.database
          .into(appsTable!)
          .insertOnConflictUpdate(
            App(
              id: const Uuid().v4().toString(),
              name: "Files",
              slug: 'files',
              group: "collections",
              order: 10,
              icon: 0xe2a3,
              route: "/files",
            ),
          );
      appsAdded++;

      await m.database
          .into(appsTable)
          .insertOnConflictUpdate(
            App(
              id: const Uuid().v4().toString(),
              name: "Email",
              slug: 'email',
              group: "collections",
              order: 30,
              icon: 0xf705,
              route: "/email",
            ),
          );
      appsAdded++;

      await m.database
          .into(appsTable)
          .insertOnConflictUpdate(
            App(
              id: const Uuid().v4().toString(),
              name: "Social Networks",
              slug: 'social',
              group: "collections",
              order: 50,
              icon: 0xe486,
              route: "/social",
            ),
          );
      appsAdded++;

      await m.database
          .into(appsTable)
          .insertOnConflictUpdate(
            App(
              id: const Uuid().v4().toString(),
              name: "Photos",
              slug: 'photos',
              group: "app",
              order: 20,
              icon: 0xf80d,
              route: "/photos",
            ),
          );
      appsAdded++;

      await m.database
          .into(appsTable)
          .insertOnConflictUpdate(
            App(
              id: const Uuid().v4().toString(),
              name: "AI Chat",
              slug: 'aichat',
              group: "app",
              order: 15,
              icon: 0xe0b7,
              route: "/aichat",
            ),
          );
      appsAdded++;

      return Future(() => appsAdded);
    } catch (err) {
      logger.e(err);
      rethrow;
    }
  }
}

LazyDatabase _openConnection(String? path, String? name, bool useMemoryDb) {
  if (path == null || name == null) {
    throw ("Path or Name not provided, can not start scanner");
  }
  // the LazyDatabase util lets us find the right location for the file async.
  return LazyDatabase(() async {
    AppLogger(null).i('Initialize Database | path=$path');
    //check app startup initialization
    io.File file = io.File(p.join(path!, 'data', name));
    path = file.path;

    // Make sqlite3 pick a more suitable location for temporary files - the
    // one from the system may be inaccessible due to ios/mac app sandbox.
    // We can't access /tmp on Android, which sqlite3 would try by default.
    // Explicitly tell it about the correct temporary directory.
    sqlite3.tempDirectory = (await getTemporaryDirectory()).path;

    AppLogger(null).i("Opening Database | $path");
    if (!useMemoryDb) {
      return NativeDatabase(
        file,
        logStatements: false,
        cachePreparedStatements: true,
        setup: null,
      );
      //return NativeDatabase.createInBackground(file, logStatements: true, cachePreparedStatements: true, setup: null);
    } else {
      return NativeDatabase.memory(
        logStatements: false,
        setup: null,
        cachePreparedStatements: false,
      );
    }
  });
}
