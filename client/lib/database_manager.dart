import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart';
import 'package:mydatastudio/custom_path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mydatastudio/modules/files/services/embedding_isolate.dart';
import 'package:uuid/uuid.dart';

class DatabaseManager {
  static final DatabaseManager _singleton = DatabaseManager._();

  /// Singleton instance of [DatabaseManager]
  static DatabaseManager get instance => _singleton;

  /// Notifies listeners when the database initialization is complete
  static ValueNotifier<bool> isInitializedNotifier = ValueNotifier(false);

  /// Flag to skip loading native extensions (for testing environments)
  static bool skipExtensionLoading = false;

  /// Flag to indicate if the app is running in a test environment
  static bool isTesting = io.Platform.environment.containsKey('FLUTTER_TEST');
  String? storagePath;
  AppDatabase? appDatabase;
  EmbeddingIsolate? _embeddingIsolate;
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

  static String? _originalSupportPath;

  Future<String> _getConfigPath() async {
    io.Directory supportPath;
    if (_originalSupportPath != null) {
      supportPath = io.Directory(_originalSupportPath!);
    } else {
      supportPath = await getApplicationSupportDirectory();
      _originalSupportPath = supportPath.path;
    }

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

  /// Updates the database configuration path
  Future<void> updateConfigPath(String newPath) async {
    io.File file = io.File(await _getConfigPath());
    var config = <String, dynamic>{};
    if (file.existsSync()) {
      config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
    config['path'] = newPath;
    file.writeAsStringSync(jsonEncode(config));
  }

  /// Checks if the given path supports WAL mode (fails on network/SMB shares).
  static Future<bool> testPathSupportsWal(String storagePath) async {
    final testDbDir = io.Directory(p.join(storagePath, 'data'));
    if (!testDbDir.existsSync()) {
      try {
        testDbDir.createSync(recursive: true);
      } catch (_) {
        return false;
      }
    }
    final testDbFile = io.File(p.join(testDbDir.path, 'wal_test_probe.db'));
    try {
      // Attempt to open the database.
      final db = await Database.open(testDbFile.path);
      await db.close();
      // Clean up test files.
      try {
        if (testDbFile.existsSync()) testDbFile.deleteSync();
        final shmFile = io.File('${testDbFile.path}-shm');
        if (shmFile.existsSync()) shmFile.deleteSync();
        final walFile = io.File('${testDbFile.path}-wal');
        if (walFile.existsSync()) walFile.deleteSync();
      } catch (_) {}
      return true;
    } catch (e) {
      // Clean up test files if created.
      try {
        if (testDbFile.existsSync()) testDbFile.deleteSync();
        final shmFile = io.File('${testDbFile.path}-shm');
        if (shmFile.existsSync()) shmFile.deleteSync();
        final walFile = io.File('${testDbFile.path}-wal');
        if (walFile.existsSync()) walFile.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  Future<AppDatabase> initializeDatabase() async {
    if (isTesting) {
      storagePath = p.dirname(await _getConfigPath());
    } else {
      io.File file = io.File(await _getConfigPath());
      var config = jsonDecode(file.readAsStringSync());
      storagePath = config['path'];
    }
    String path = storagePath!;

    // Ensure the global appDataDirectory subject has the value
    MainApp.appDataDirectory.add(path);

    // Override application support path globally so aichat, google_fonts, etc. use the selected storagePath
    if (PathProviderPlatform.instance is! CustomPathProviderPlatform) {
      PathProviderPlatform.instance = CustomPathProviderPlatform(
        PathProviderPlatform.instance,
        path,
      );
    } else {
      final original =
          (PathProviderPlatform.instance as CustomPathProviderPlatform)
              .original;
      PathProviderPlatform.instance = CustomPathProviderPlatform(
        original,
        path,
      );
    }

    // start database
    appDatabase = await _openDatabase(path);

    // start database repository
    _repository = DatabaseRepository(appDatabase!);

    if (!isTesting) {
      // start scanners
      await _startScanners();

      // start embedding isolate
      await _startEmbeddingIsolate(path);
    }

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
      io.Directory(p.join(storagePath, 'data')).createSync(recursive: true);
      io.Directory(p.join(storagePath, 'keys')).createSync(recursive: true);
      io.Directory(p.join(storagePath, 'files')).createSync(recursive: true);

      //on app startup, start db.
      AppDatabase database = await AppDatabase.create(
        null,
        storagePath,
        AppConstants.dbName,
      );
      logger.i("DB Started | schema version=${database.schemaVersion}");

      return database;
    } catch (err) {
      //unknown error
      logger.e(err);
      if (err is io.FileSystemException) {
        rethrow;
      }
      throw Exception(err);
    }
  }

  Future<void> _startEmbeddingIsolate(String storagePath) async {
    _embeddingIsolate = EmbeddingIsolate();
    await _embeddingIsolate!.start(
      storagePath,
      AppConstants.dbName,
      RootIsolateToken.instance!,
    );
  }

  void dispose() {
    _embeddingIsolate?.stop();
    _embeddingIsolate = null;

    appDatabase?.close();
    appDatabase = null;
    _repository = null;
    isInitializedNotifier.value = false;
    _originalSupportPath = null;
    if (PathProviderPlatform.instance is CustomPathProviderPlatform) {
      PathProviderPlatform.instance =
          (PathProviderPlatform.instance as CustomPathProviderPlatform)
              .original;
    }
  }

  Future<void> _startScanners() async {
    ScannerManager sm = ScannerManager(appDatabase!);
    MainApp.scannerManager = sm;
    sm.startScanners();
  }
}

class AppDatabase {
  final Database _db;
  final AppLogger logger = AppLogger(null);

  String? path;
  String? name;

  AppDatabase(this._db);

  int get schemaVersion => 16;

  Database get rawDb => _db;

  static Future<AppDatabase> create(
    String? connection,
    String? storagePath,
    String? dbName,
  ) async {
    if (storagePath == null || dbName == null) {
      throw Exception("Path or Name not provided for database opening");
    }
    final dbFile = io.File(p.join(storagePath, 'data', dbName));
    if (!dbFile.parent.existsSync()) {
      dbFile.parent.createSync(recursive: true);
    }
    final Database db = await Database.open(dbFile.path);

    final appDb = AppDatabase(db);
    appDb.path = storagePath;
    appDb.name = dbName;

    await appDb.initSchema();
    return appDb;
  }

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> params = const [],
  ]) => _db.select(sql, params);
  Future<WriteResult> execute(String sql, [List<Object?> params = const []]) =>
      _db.execute(sql, params);
  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) =>
      _db.executeBatch(sql, paramSets);
  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) =>
      _db.transaction(body);
  Stream<List<Map<String, Object?>>> stream(
    String sql, [
    List<Object?> params = const [],
  ]) => _db.stream(sql, params);
  Future<void> close() => _db.close();

  Future<void> initSchema() async {
    // Check if table 'apps' already exists to determine if initialization is required
    final tables = await _db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='apps'",
    );
    if (tables.isEmpty) {
      logger.i("AppDatabase: Initializing schema...");
      for (final sql in schemaDDL) {
        await _db.execute(sql);
      }
      logger.i("AppDatabase: Loading initial data...");
      await _loadInitialData(_db);
      logger.i("AppDatabase: Initializing vector index...");
      await _initVectorIndex();
    }
  }

  Future<void> _initVectorIndex() async {
    try {
      await _db.execute(
        "SELECT vector_init('files_embeddings', 'qwen3_8b_embedding', 'type=FLOAT32,dimension=2048')",
      );
    } catch (e) {
      logger.w('Could not initialize vector index (extension not loaded?): $e');
    }
  }

  static Future<int> _loadInitialData(Database db) async {
    try {
      int appsAdded = 0;

      final apps = [
        {
          'id': const Uuid().v4().toString(),
          'name': 'Files',
          'slug': 'files',
          'group': 'collections',
          'order': 10,
          'icon': 0xe2a3,
          'route': '/files',
        },
        {
          'id': const Uuid().v4().toString(),
          'name': 'Email',
          'slug': 'email',
          'group': 'collections',
          'order': 30,
          'icon': 0xf705,
          'route': '/email',
        },
        {
          'id': const Uuid().v4().toString(),
          'name': 'Social Networks',
          'slug': 'social',
          'group': 'collections',
          'order': 50,
          'icon': 0xe486,
          'route': '/social',
        },
        {
          'id': const Uuid().v4().toString(),
          'name': 'Photos',
          'slug': 'photos',
          'group': 'app',
          'order': 20,
          'icon': 0xf80d,
          'route': '/photos',
        },
        {
          'id': const Uuid().v4().toString(),
          'name': 'AI Chat',
          'slug': 'aichat',
          'group': 'app',
          'order': 15,
          'icon': 0xe0b7,
          'route': '/aichat',
        },
      ];

      for (final app in apps) {
        await db.execute(
          'INSERT INTO apps (id, name, slug, "group", "order", icon, route) '
          'VALUES (?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(slug) DO UPDATE SET '
          'name = excluded.name, '
          '"group" = excluded."group", '
          '"order" = excluded."order", '
          'icon = excluded.icon, '
          'route = excluded.route',
          [
            app['id'],
            app['name'],
            app['slug'],
            app['group'],
            app['order'],
            app['icon'],
            app['route'],
          ],
        );
        appsAdded++;
      }

      return appsAdded;
    } catch (err) {
      AppLogger(null).e(err);
      rethrow;
    }
  }

  static const List<String> schemaDDL = [
    // apps
    '''
    CREATE TABLE IF NOT EXISTS apps (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      slug TEXT UNIQUE NOT NULL,
      "group" TEXT NOT NULL DEFAULT 'collections',
      "order" INTEGER NOT NULL DEFAULT 0,
      icon INTEGER,
      route TEXT NOT NULL DEFAULT '/'
    );
    ''',
    // app_users
    '''
    CREATE TABLE IF NOT EXISTS app_users (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      email TEXT NOT NULL,
      password TEXT NOT NULL,
      local_storage_path TEXT NOT NULL
    );
    ''',
    // collections
    '''
    CREATE TABLE IF NOT EXISTS collections (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      path TEXT NOT NULL,
      type TEXT NOT NULL,
      scanner TEXT NOT NULL,
      scan_status TEXT NOT NULL,
      oauth_service TEXT,
      access_token TEXT,
      refresh_token TEXT,
      id_token TEXT,
      user_id TEXT,
      expiration INTEGER,
      last_scan_date INTEGER,
      needs_re_auth INTEGER NOT NULL DEFAULT 0,
      download_local_copy INTEGER NOT NULL DEFAULT 0,
      local_copy_path TEXT
    );
    ''',
    // emails
    '''
    CREATE TABLE IF NOT EXISTS emails (
      id TEXT PRIMARY KEY,
      collection_id TEXT NOT NULL,
      date INTEGER NOT NULL,
      "from" TEXT NOT NULL,
      "to" TEXT NOT NULL,
      cc TEXT,
      subject TEXT NOT NULL,
      snippet TEXT,
      html_body TEXT,
      plain_body TEXT,
      labels TEXT,
      headers TEXT,
      folder_id TEXT,
      message_id TEXT,
      thread_id TEXT,
      is_read INTEGER NOT NULL DEFAULT 0,
      has_attachments INTEGER NOT NULL DEFAULT 0,
      is_deleted INTEGER NOT NULL DEFAULT 0,
      uid INTEGER
    );
    ''',
    '''
    CREATE INDEX IF NOT EXISTS email_folderid_idx ON emails (folder_id);
    ''',
    '''
    CREATE INDEX IF NOT EXISTS email_comp_sync_idx ON emails (collection_id, folder_id, date);
    ''',
    // email_folders
    '''
    CREATE TABLE IF NOT EXISTS email_folders (
      id TEXT NOT NULL,
      collection_id TEXT NOT NULL,
      name TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'user',
      messages_total INTEGER NOT NULL,
      messages_unread INTEGER NOT NULL,
      parent_id TEXT,
      PRIMARY KEY (id, collection_id),
      FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE
    );
    ''',
    // files
    '''
    CREATE TABLE IF NOT EXISTS files (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      path TEXT NOT NULL,
      parent TEXT NOT NULL,
      date_created INTEGER,
      date_last_modified INTEGER,
      last_scanned_date INTEGER,
      collection_id TEXT NOT NULL,
      content_type TEXT NOT NULL,
      size INTEGER NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0,
      thumbnail TEXT,
      download_url TEXT,
      email_id TEXT,
      latitude REAL,
      longitude REAL,
      local_path TEXT
    );
    ''',
    // folders
    '''
    CREATE TABLE IF NOT EXISTS folders (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      path TEXT NOT NULL,
      parent TEXT NOT NULL,
      date_created INTEGER,
      date_last_modified INTEGER,
      last_scanned_date INTEGER,
      thumbnail TEXT,
      download_url TEXT,
      email_id TEXT,
      collection_id TEXT NOT NULL
    );
    ''',
    // albums
    '''
    CREATE TABLE IF NOT EXISTS albums (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL
    );
    ''',
    // files_embeddings
    '''
    CREATE TABLE IF NOT EXISTS files_embeddings (
      file_id TEXT PRIMARY KEY,
      qwen3_8b_embedding BLOB NOT NULL,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    ''',
    // providers
    '''
    CREATE TABLE IF NOT EXISTS providers (
      service TEXT PRIMARY KEY,
      client_id TEXT NOT NULL,
      client_secret TEXT NOT NULL,
      api_key TEXT NOT NULL,
      permissions TEXT
    );
    ''',
  ];
}
