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
import 'package:resqlite_vector/resqlite_vector.dart';
import 'package:mydatastudio/custom_path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mydatastudio/modules/files/services/embedding_isolate.dart';
import 'package:mydatastudio/modules/files/services/file_description_isolate.dart';
import 'package:mydatastudio/modules/email/services/email_embedding_isolate.dart';
import 'package:mydatastudio/modules/email/services/searchable_body.dart';
import 'package:mydatastudio/modules/search/services/email_contact_repository.dart';
import 'package:mydatastudio/modules/search/services/place_repository.dart';
import 'package:mydatastudio/services/vault_manager.dart';
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
  String? databaseDirectoryPath;
  AppDatabase? appDatabase;
  EmbeddingIsolate? _embeddingIsolate;
  EmailEmbeddingIsolate? _emailEmbeddingIsolate;
  FileDescriptionIsolate? _fileDescriptionIsolate;
  DatabaseRepository? _repository;
  bool _backgroundServicesStarted = false;
  VoidCallback? _vaultUnlockListener;
  final AppLogger logger = AppLogger(null);

  DatabaseManager._() {
    _vaultUnlockListener = () {
      if (VaultManager.instance.unlocked.value) {
        unawaited(startBackgroundServices());
      } else {
        stopBackgroundServices();
      }
    };
    VaultManager.instance.unlocked.addListener(_vaultUnlockListener!);
  }

  /// Returns the [DatabaseRepository] instance
  DatabaseRepository? get repository {
    return _repository;
  }

  /// Returns the [AppDatabase] instance
  AppDatabase? get database {
    return appDatabase;
  }

  static String? _originalSupportPath;

  /// Gets the real local application support directory path, ignoring any custom overrides.
  static Future<String> getRealApplicationSupportPath() async {
    if (_originalSupportPath != null) {
      return _originalSupportPath!;
    }
    final platform = PathProviderPlatform.instance;
    if (platform is CustomPathProviderPlatform) {
      final originalPath = await platform.original.getApplicationSupportPath();
      if (originalPath != null) {
        _originalSupportPath = originalPath;
        return originalPath;
      }
    }
    final supportDir = await getApplicationSupportDirectory();
    _originalSupportPath = supportDir.path;
    return supportDir.path;
  }

  Future<String> _getConfigPath() async {
    final supportPath = await getRealApplicationSupportPath();
    MainApp.supportDirectory.add(io.Directory(supportPath));

    // Look for config file with user selected path for DB and Files
    io.File file = io.File(p.join(supportPath, AppConstants.configFileName));
    return file.absolute.path;
  }

  /// Checks if the database configuration file exists
  Future<bool> isDatabaseConfigured() async {
    // Look for config file with user selected path for DB and Files
    io.File file = io.File(await _getConfigPath());
    return file.existsSync();
  }

  /// Updates the database and storage configuration paths
  Future<void> updateConfigPath(String storagePath) async {
    io.File file = io.File(await _getConfigPath());
    var config = <String, dynamic>{};
    if (file.existsSync()) {
      try {
        config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {}
    }

    final supportsWal = await testPathSupportsWal(storagePath);
    String databasePath = storagePath;
    if (!supportsWal) {
      final realSupportPath = await getRealApplicationSupportPath();
      databasePath = realSupportPath;
    }

    config.remove('path');
    config['storage'] = storagePath;
    config['database'] = databasePath;

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
    final uniqueId = DateTime.now().microsecondsSinceEpoch;
    final testDbFile = io.File(
      p.join(testDbDir.path, 'wal_test_probe_$uniqueId.db'),
    );
    try {
      // Attempt to open the database.
      final db = await Database.open(testDbFile.path);
      // Explicitly try to enable WAL mode.
      final result = await db.select('PRAGMA journal_mode=WAL;');
      final mode = result.isNotEmpty ? result.first.values.first as String : '';
      await db.close();

      // Clean up test files.
      try {
        if (testDbFile.existsSync()) testDbFile.deleteSync();
        final shmFile = io.File('${testDbFile.path}-shm');
        if (shmFile.existsSync()) shmFile.deleteSync();
        final walFile = io.File('${testDbFile.path}-wal');
        if (walFile.existsSync()) walFile.deleteSync();
      } catch (_) {}

      if (mode.toLowerCase() != 'wal') {
        AppLogger(null).d(
          "testPathSupportsWal: path does not support WAL mode (returned: $mode)",
        );
        return false;
      }
      return true;
    } catch (e) {
      // Clean up test files if created.
      AppLogger(null).w("testPathSupportsWal failed: $e");
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
      databaseDirectoryPath = storagePath;
    } else {
      io.File file = io.File(await _getConfigPath());
      var config = jsonDecode(file.readAsStringSync());
      storagePath = config['storage'] ?? config['path'];
      databaseDirectoryPath = config['database'] ?? storagePath;
    }
    String path = storagePath!;

    if (!isTesting) {
      final storageDir = io.Directory(path);
      bool isAccessible = false;
      try {
        if (storageDir.existsSync()) {
          storageDir.listSync();
          isAccessible = true;
        }
      } catch (e) {
        isAccessible = false;
      }

      if (!isAccessible) {
        throw io.FileSystemException(
          "The storage directory is not accessible. Please ensure your network drive is connected or choose a new location.",
          path,
        );
      }
    }

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
    appDatabase = await _openDatabase(databaseDirectoryPath!);

    // start database repository
    _repository = DatabaseRepository(appDatabase!);

    isInitializedNotifier.value = true;

    // Not awaited: a first launch imports ~70k gazetteer rows, and no part of
    // startup depends on them. The import runs in one transaction, so another
    // connection sees either no gazetteer or all of it — never a half-loaded
    // one that would resolve `near:banff` to nothing and quietly demote it to
    // free text. Skipped under test, where the asset bundle is not present and
    // the tables are built per-test anyway.
    if (!isTesting) {
      unawaited(
        PlaceRepository(appDatabase!).importIfEmpty().catchError((Object e) {
          logger.w(
            'DatabaseManager: gazetteer import failed, near: disabled: $e',
          );
          return 0;
        }),
      );
    }

    // If vault is already unlocked at initialization (e.g. auto-login flow), start background services.
    if (!isTesting && VaultManager.instance.isUnlocked) {
      unawaited(startBackgroundServices());
    }

    return appDatabase!;
  }

  /// Bumped by every start and every stop, so a startup still working through
  /// its staggered delays can tell it has been superseded.
  int _startGeneration = 0;

  Future<void> startBackgroundServices() async {
    if (_backgroundServicesStarted || isTesting || appDatabase == null) return;
    _backgroundServicesStarted = true;
    final generation = ++_startGeneration;

    logger.i("Starting background isolates and scanners (vault unlocked)...");

    // 1. Start scanners
    await _startScanners();

    // The stagger below is a window in which the vault can lock and
    // stopBackgroundServices can run. It nulls the isolate fields, but this
    // call is still in flight — without the generation check it would go on to
    // assign fresh isolates that nothing holds a reference to, leaving them
    // running against a locked vault with no way to stop them.
    // 2. Stagger background embedding isolate startup by 500ms to avoid concurrent SQLite connection opening contention
    await Future.delayed(const Duration(milliseconds: 500));
    if (generation != _startGeneration) return;
    if (appDatabase != null && _embeddingIsolate == null) {
      await _startEmbeddingIsolate(appDatabase!.path!);
    }

    await Future.delayed(const Duration(milliseconds: 500));
    if (generation != _startGeneration) return;
    if (appDatabase != null && _emailEmbeddingIsolate == null) {
      await _startEmailEmbeddingIsolate(appDatabase!.path!);
    }

    await Future.delayed(const Duration(milliseconds: 500));
    if (generation != _startGeneration) return;
    if (appDatabase != null && _fileDescriptionIsolate == null) {
      await _startFileDescriptionIsolate(appDatabase!.path!);
    }
  }

  void stopBackgroundServices() {
    _backgroundServicesStarted = false;
    _startGeneration++;
    unawaited(_embeddingIsolate?.stop());
    _embeddingIsolate = null;
    unawaited(_emailEmbeddingIsolate?.stop());
    _emailEmbeddingIsolate = null;
    unawaited(_fileDescriptionIsolate?.stop());
    _fileDescriptionIsolate = null;
  }

  Future<AppDatabase> _openDatabase(String dbDir) async {
    try {
      if (this.database != null) {
        return this.database!;
      }

      //make sure database root dir exists
      io.Directory(dbDir).createSync(recursive: true);
      io.Directory(p.join(dbDir, 'data')).createSync(recursive: true);

      // also make sure keys and files directories exist in configured storagePath
      if (storagePath != null) {
        io.Directory(storagePath!).createSync(recursive: true);
        io.Directory(p.join(storagePath!, 'keys')).createSync(recursive: true);
        io.Directory(p.join(storagePath!, 'files')).createSync(recursive: true);
      }

      //on app startup, start db.
      AppDatabase database = await AppDatabase.create(
        null,
        dbDir,
        AppConstants.dbName,
      );
      if (database.path != storagePath) {
        logger.i(
          "SQLite WAL mode is unsupported on storagePath. Database is stored locally at: ${database.path}",
        );
      } else {
        logger.i(
          "DB Started | schema version=${database.schemaVersion} | path=${database.path}",
        );
      }

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

  Future<void> _startEmailEmbeddingIsolate(String storagePath) async {
    _emailEmbeddingIsolate = EmailEmbeddingIsolate();
    await _emailEmbeddingIsolate!.start(
      storagePath,
      AppConstants.dbName,
      RootIsolateToken.instance!,
    );
  }

  Future<void> _startFileDescriptionIsolate(String storagePath) async {
    _fileDescriptionIsolate = FileDescriptionIsolate();
    await _fileDescriptionIsolate!.start(
      storagePath,
      AppConstants.dbName,
      RootIsolateToken.instance!,
    );
  }

  void pauseEmbeddingIsolates() {
    logger.d("Pausing embedding isolates for active scanner/import");
    _embeddingIsolate?.pause();
    _emailEmbeddingIsolate?.pause();
    _fileDescriptionIsolate?.pause();
  }

  void resumeEmbeddingIsolates() {
    logger.d(
      "Resuming embedding isolates after active scanner/import finished",
    );
    _embeddingIsolate?.resume();
    _emailEmbeddingIsolate?.resume();
    _fileDescriptionIsolate?.resume();
  }

  void dispose() {
    if (_vaultUnlockListener != null) {
      VaultManager.instance.unlocked.removeListener(_vaultUnlockListener!);
      _vaultUnlockListener = null;
    }
    stopBackgroundServices();

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

  int get schemaVersion => 1;

  Database get rawDb => _db;

  static Future<AppDatabase> create(
    String? connection,
    String? storagePath,
    String? dbName,
  ) async {
    if (storagePath == null || dbName == null) {
      throw Exception("Path or Name not provided for database opening");
    }

    String finalDbDir = storagePath;
    // Check if the storagePath supports WAL. If not, redirect database to local Application Support Directory.
    final supportsWal = await DatabaseManager.testPathSupportsWal(storagePath);
    if (!supportsWal) {
      final realSupportPath =
          await DatabaseManager.getRealApplicationSupportPath();
      finalDbDir = realSupportPath;
    }

    final dbFile = io.File(p.join(finalDbDir, 'data', dbName));
    AppLogger(null).d("AppDatabase.create: opening db at ${dbFile.path}");
    if (!dbFile.parent.existsSync()) {
      dbFile.parent.createSync(recursive: true);
    }

    // vector_init() must be called on every connection, but requires the
    // files_embeddings table to already exist. For brand-new databases the
    // table doesn't exist yet, so we create the schema first on a plain
    // connection, then reopen with the vector index registered.
    // (sqlite-vector README: "For migrations that create the table, run the
    //  migration first and reopen the database with this index configured.")
    final vectorExtension = SqliteVectorExtension(
      indexes: [
        SqliteVectorIndex(
          table: 'files_embeddings',
          column: 'qwen3_vl_embedding',
          dimension: 2048,
        ),
        SqliteVectorIndex(
          table: 'emails_embeddings',
          column: 'qwen3_vl_embedding',
          dimension: 2048,
        ),
      ],
    );

    // Step 1: Open without vector index to let initSchema create/migrate all tables
    // (including files_embeddings) before vector_init is called.
    Database db = await Database.open(
      dbFile.path,
      extensions: [SqliteVectorExtension()],
    );
    await db.execute('PRAGMA busy_timeout = 5000;');

    final bootstrapDb = AppDatabase(db);
    bootstrapDb.path = finalDbDir;
    bootstrapDb.name = dbName;
    await bootstrapDb.initSchema();
    await db.close();

    // Step 2: Reopen with vector indexes now that files_embeddings is migrated.
    db = await Database.open(dbFile.path, extensions: [vectorExtension]);
    await db.execute('PRAGMA busy_timeout = 5000;');

    final appDb = AppDatabase(db);
    appDb.path = finalDbDir;
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
      await _seedAichatModels(_db);
      await _seedAichatSkills(_db);
    }
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS emails_embeddings (
        email_id TEXT NOT NULL,
        chunk_index INTEGER NOT NULL DEFAULT 0,
        qwen3_vl_embedding BLOB,
        model_version TEXT,
        PRIMARY KEY (email_id, chunk_index),
        FOREIGN KEY (email_id) REFERENCES emails(id) ON DELETE CASCADE
      );
    ''');
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS file_tags (
        file_id TEXT NOT NULL,
        tag TEXT NOT NULL,
        PRIMARY KEY (file_id, tag),
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      );
    ''');
    await _db.execute(
      'CREATE INDEX IF NOT EXISTS file_tags_tag_idx ON file_tags (tag);',
    );
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS album_files (
        album_id TEXT NOT NULL,
        file_id TEXT NOT NULL,
        PRIMARY KEY (album_id, file_id),
        FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      );
    ''');
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS file_landmarks (
        file_id TEXT NOT NULL,
        landmark TEXT NOT NULL,
        PRIMARY KEY (file_id, landmark),
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
      );
    ''');
    await _db.execute(
      'CREATE INDEX IF NOT EXISTS file_landmarks_landmark_idx '
      'ON file_landmarks (landmark);',
    );
    await _migrateFilesEmbeddingsKey();
    await _migrateEmailEmbeddingsToChunks();
    final added = await _addMissingColumns();

    // Only on the open that introduces the column, so a large archive pays for
    // this pass once rather than on every launch.
    if (added.contains('files.is_inline')) {
      await _backfillInlineAttachments();
    }

    await _reapOrphanedArtifacts();

    // Strictly before _createSearchIndexes: that method creates
    // `emails_contacts` with IF NOT EXISTS, which on an install still holding
    // the old `contacts` table would happily make a second, empty one beside
    // it — leaving the archive with a populated table nothing reads and an
    // empty table everything reads.
    await _renameContactsTable();

    // Strictly after _addMissingColumns: files_fts indexes `description`, a
    // column added long after the initial schema. Creating the trigger that
    // reads `new.description` before that ALTER lands would build it against
    // a table that has no such column, and the failure would surface later as
    // a broken INSERT on an upgraded install only.
    await _createSearchIndexes();
    await _backfillSearchIndexes();
    await _createGeoIndexes();
  }

  /// Creates the gazetteer table and the coordinate index `near:` scans.
  ///
  /// Separate from [_createSearchIndexes] because nothing here is a text index:
  /// `near:banff` is answered by turning one place name into a centre point and
  /// running a radius against coordinates already on `files`.
  ///
  /// The rows are loaded separately — see [GazetteerImporter]. Reading a bundled
  /// asset needs the Flutter binding, and scanner isolates open their own
  /// [AppDatabase] (and so run this method) without one.
  ///
  /// No spatial index exists to build: resqlite's SQLite is compiled with
  /// `SQLITE_ENABLE_MATH_FUNCTIONS` but not R-Tree, so a radius is a
  /// bounding-box scan narrowed by haversine in SQL. That is cheap here — a few
  /// float comparisons per row, against 10% of the library that carries GPS at
  /// all — and it is why H3 cells would buy nothing.
  Future<void> _createGeoIndexes() async {
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS places (
        id         INTEGER PRIMARY KEY,
        name       TEXT NOT NULL,
        ascii_name TEXT NOT NULL,
        latitude   REAL NOT NULL,
        longitude  REAL NOT NULL,
        country    TEXT,
        admin1     TEXT,
        population INTEGER
      );
    ''');
    // Both spellings are indexed: a query may type either "Zürich" or "Zurich",
    // and only `ascii_name` holds the second.
    await _db.execute(
      'CREATE INDEX IF NOT EXISTS places_ascii_idx '
      'ON places (ascii_name COLLATE NOCASE);',
    );
    await _db.execute(
      'CREATE INDEX IF NOT EXISTS places_name_idx '
      'ON places (name COLLATE NOCASE);',
    );
    await _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_files_geo '
      'ON files (latitude, longitude);',
    );
  }

  /// One-time sweep of artifacts stranded by the delete paths before they
  /// cleaned up after themselves.
  ///
  /// Thumbnails are the real target: no cascade covers the filesystem, and
  /// until the delete paths started removing them every deleted file left its
  /// cached jpeg behind. The embedding half is cheap insurance for archives
  /// created before resqlite began enabling `PRAGMA foreign_keys` on every
  /// connection, when the declared cascades genuinely did not fire.
  ///
  /// Gated on `PRAGMA user_version` rather than run on every open: this is a
  /// migration, not maintenance, and the thumbnail half stats every file under
  /// the cache directory — six figures for a large photo archive. The gate is
  /// also what keeps it from running twice, since [create] calls [initSchema]
  /// on two connections.
  Future<void> _reapOrphanedArtifacts() async {
    const reapVersion = 1;

    final rows = await _db.select('PRAGMA user_version');
    final current = rows.isEmpty ? 0 : (rows.first.values.first as int? ?? 0);
    if (current >= reapVersion) return;

    for (final table in const [
      ('files_embeddings', 'file_id', 'files'),
      ('emails_embeddings', 'email_id', 'emails'),
    ]) {
      final (child, column, parent) = table;
      final result = await _db.execute(
        'DELETE FROM $child WHERE $column NOT IN (SELECT id FROM $parent)',
      );
      if (result.affectedRows > 0) {
        logger.i(
          "AppDatabase: reaped ${result.affectedRows} orphaned rows from $child",
        );
      }
    }

    await _reapOrphanedThumbnails();
    await _db.execute('PRAGMA user_version = $reapVersion');
  }

  /// Deletes cached thumbnails no `files` row references any more.
  ///
  /// Walks the cache rather than the table: a thumbnail whose row is gone can
  /// only be found from the disk side. Keys are compared as stored — the
  /// relative `<collectionId>/<ab>/<hash>.jpg` form (see `ThumbnailCache`).
  Future<void> _reapOrphanedThumbnails() async {
    final storageRoot = MainApp.appDataDirectory.valueOrNull;
    if (storageRoot == null) return;

    final rootDir = io.Directory(p.join(storageRoot, 'thumbnails'));
    if (!await rootDir.exists()) return;

    final live =
        (await _db.select(
          "SELECT thumbnail FROM files WHERE thumbnail IS NOT NULL",
        )).map((r) => r['thumbnail'] as String).toSet();

    var reaped = 0;
    await for (final entity in rootDir.list(recursive: true)) {
      if (entity is! io.File) continue;
      final key = p.relative(entity.path, from: rootDir.path);
      if (live.contains(key)) continue;
      try {
        await entity.delete();
        reaped++;
      } catch (e) {
        logger.w("AppDatabase: could not delete stale thumbnail $key: $e");
      }
    }
    if (reaped > 0) {
      logger.i("AppDatabase: reaped $reaped orphaned thumbnails from disk");
    }
  }

  /// Renames the derived address index `contacts` → `emails_contacts`.
  ///
  /// The table only ever held addresses parsed out of `emails.from`/`to`/`cc`,
  /// so `contacts` overstated it: it is an email-derived search index, not a
  /// contact book. The plain name is reserved for a future root-level contacts
  /// module, which will be *person*-level — this table is keyed by address, and
  /// one person routinely owns several rows here.
  ///
  /// Renamed rather than dropped and rebuilt, even though the contents are
  /// fully derivable. `backfillFromEmails` re-parses every message in the
  /// archive, and on an archive this size that is real work to repeat for a
  /// change that moves no data. SQLite carries the existing indexes across a
  /// RENAME under their old names, so they are dropped here and recreated by
  /// [_createSearchIndexes] — otherwise an install would keep `contacts_*`
  /// index names against a table that no longer answers to `contacts`.
  ///
  /// Not gated on `user_version`: the guard is the rename itself, which is a
  /// no-op once `emails_contacts` exists. That is cheaper than a version bump
  /// and cannot be skipped by an install that jumped several versions.
  Future<void> _renameContactsTable() async {
    final existing = await _db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('contacts', 'emails_contacts')",
    );
    final names = existing.map((r) => r['name'] as String).toSet();
    if (!names.contains('contacts') || names.contains('emails_contacts')) {
      return;
    }

    await _db.execute('ALTER TABLE contacts RENAME TO emails_contacts');
    for (final index in const [
      'contacts_name_idx',
      'contacts_local_idx',
      'contacts_rank_idx',
    ]) {
      await _db.execute('DROP INDEX IF EXISTS $index');
    }
    logger.i('AppDatabase: renamed contacts -> emails_contacts');
  }

  /// Creates the keyword-search indexes: two FTS5 virtual tables and the
  /// derived `emails_contacts` index.
  ///
  /// Deliberately not part of [schemaDDL]. That list only runs for a brand-new
  /// database, so an existing install would never see these; running them here
  /// covers both cases from one place. Every statement is `IF NOT EXISTS`,
  /// which matters because [create] calls [initSchema] on two connections.
  ///
  /// Both FTS5 tables are **external-content** (`content='<table>'`): FTS5
  /// stores only the inverted index and reads column values back from the real
  /// row. Storing the text twice would roughly double the database for an
  /// archive whose bulk is already email bodies.
  ///
  /// Sync is by trigger rather than from the write paths in Dart. Every scanner
  /// (Gmail, Yahoo, Outlook, PST, local FS, Drive) reaches these tables through
  /// the main-isolate write relay, so a trigger cannot be bypassed — whereas a
  /// Dart-side call is one thing a sixth scanner can forget to make.
  Future<void> _createSearchIndexes() async {
    // An earlier version indexed `plain_body`, which left HTML-only mail — a
    // third of a real archive — with no searchable body at all. `IF NOT
    // EXISTS` cannot widen an existing virtual table, so the old shape is
    // dropped and rebuilt; `_backfillSearchIndexes` repopulates it.
    final ftsColumns = await _db.select('PRAGMA table_info(emails_fts)');
    final indexesBodyText = ftsColumns.any((r) => r['name'] == 'body_text');
    if (ftsColumns.isNotEmpty && !indexesBodyText) {
      logger.i('AppDatabase: rebuilding emails_fts to index body_text');
      await _db.execute('DROP TRIGGER IF EXISTS emails_fts_ai');
      await _db.execute('DROP TRIGGER IF EXISTS emails_fts_au');
      await _db.execute('DROP TRIGGER IF EXISTS emails_fts_ad');
      await _db.execute('DROP TABLE IF EXISTS emails_fts');
    }

    // unicode61 + remove_diacritics: "resume" should find "résumé", and a
    // personal archive is exactly where accented names turn up.
    await _db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS emails_fts USING fts5(
        subject, "from", "to", cc, body_text,
        content='emails', content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
      );
    ''');
    await _db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
        name, path, description,
        content='files', content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
      );
    ''');

    // An external-content delete must replay the OLD column values: FTS5 keeps
    // no copy of the row, so it can only find the terms to retract by being
    // handed what they were. Passing new values, or omitting them, silently
    // leaves stale terms pointing at a row that no longer matches.
    await _db.execute('''
      CREATE TRIGGER IF NOT EXISTS emails_fts_ai AFTER INSERT ON emails BEGIN
        INSERT INTO emails_fts(rowid, subject, "from", "to", cc, body_text)
        VALUES (new.rowid, new.subject, new."from", new."to", new.cc,
                new.body_text);
      END;
    ''');
    await _db.execute('''
      CREATE TRIGGER IF NOT EXISTS emails_fts_ad AFTER DELETE ON emails BEGIN
        INSERT INTO emails_fts(emails_fts, rowid, subject, "from", "to", cc,
                               body_text)
        VALUES ('delete', old.rowid, old.subject, old."from", old."to", old.cc,
                old.body_text);
      END;
    ''');
    await _db.execute('''
      CREATE TRIGGER IF NOT EXISTS emails_fts_au AFTER UPDATE ON emails BEGIN
        INSERT INTO emails_fts(emails_fts, rowid, subject, "from", "to", cc,
                               body_text)
        VALUES ('delete', old.rowid, old.subject, old."from", old."to", old.cc,
                old.body_text);
        INSERT INTO emails_fts(rowid, subject, "from", "to", cc, body_text)
        VALUES (new.rowid, new.subject, new."from", new."to", new.cc,
                new.body_text);
      END;
    ''');

    await _db.execute('''
      CREATE TRIGGER IF NOT EXISTS files_fts_ai AFTER INSERT ON files BEGIN
        INSERT INTO files_fts(rowid, name, path, description)
        VALUES (new.rowid, new.name, new.path, new.description);
      END;
    ''');
    await _db.execute('''
      CREATE TRIGGER IF NOT EXISTS files_fts_ad AFTER DELETE ON files BEGIN
        INSERT INTO files_fts(files_fts, rowid, name, path, description)
        VALUES ('delete', old.rowid, old.name, old.path, old.description);
      END;
    ''');
    await _db.execute('''
      CREATE TRIGGER IF NOT EXISTS files_fts_au AFTER UPDATE ON files BEGIN
        INSERT INTO files_fts(files_fts, rowid, name, path, description)
        VALUES ('delete', old.rowid, old.name, old.path, old.description);
        INSERT INTO files_fts(rowid, name, path, description)
        VALUES (new.rowid, new.name, new.path, new.description);
      END;
    ''');

    // `address` is stored already-lowercased and is the identity key: the same
    // mailbox reaches us in several casings, and real archives already carry
    // such duplicates. `display_name` keeps human casing for presentation.
    //
    // This one cannot be trigger-maintained like the FTS5 tables above —
    // populating it means parsing RFC 5322 (`Name <addr@host>`) and splitting
    // the comma-joined `to`/`cc` lists, neither of which is expressible in SQL.
    // See ContactIndexer.
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS emails_contacts (
        address        TEXT PRIMARY KEY,
        display_name   TEXT,
        local_part     TEXT NOT NULL,
        message_count  INTEGER NOT NULL DEFAULT 0,
        sent_count     INTEGER NOT NULL DEFAULT 0,
        first_seen     INTEGER,
        last_seen      INTEGER
      );
    ''');
    await _db.execute(
      'CREATE INDEX IF NOT EXISTS emails_contacts_name_idx '
      'ON emails_contacts (display_name COLLATE NOCASE);',
    );
    await _db.execute(
      'CREATE INDEX IF NOT EXISTS emails_contacts_local_idx '
      'ON emails_contacts (local_part COLLATE NOCASE);',
    );
    await _db.execute(
      'CREATE INDEX IF NOT EXISTS emails_contacts_rank_idx '
      'ON emails_contacts (message_count DESC);',
    );
  }

  /// Populates the FTS5 indexes for rows that predate them.
  ///
  /// The triggers in [_createSearchIndexes] only see writes from the moment
  /// they exist, so every email and file already in the archive is invisible to
  /// keyword search until this runs once.
  ///
  /// Gated on `PRAGMA user_version` for the same reasons as
  /// [_reapOrphanedArtifacts]: `'rebuild'` re-tokenizes every row of both
  /// tables, which is real work on a large archive, and the gate is also what
  /// stops it running twice given [create] calls [initSchema] on two
  /// connections.
  ///
  /// Failure here is deliberately not fatal. An empty or partial index degrades
  /// keyword search; it does not stop the app opening, and the next version
  /// bump re-attempts it.
  Future<void> _backfillSearchIndexes() async {
    const searchIndexVersion = 3;

    final rows = await _db.select('PRAGMA user_version');
    final current = rows.isEmpty ? 0 : (rows.first.values.first as int? ?? 0);
    if (current >= searchIndexVersion) return;

    try {
      logger.i('AppDatabase: building full-text search indexes...');

      // The triggers must not fire while the backfill runs. Each UPDATE would
      // issue an FTS5 'delete' carrying the row's old values, and retracting
      // terms that were never inserted — which is the case for an index just
      // recreated empty — corrupts it outright (SQLITE_CORRUPT), taking the
      // whole migration down with it.
      await _db.execute('DROP TRIGGER IF EXISTS emails_fts_ai');
      await _db.execute('DROP TRIGGER IF EXISTS emails_fts_au');
      await _db.execute('DROP TRIGGER IF EXISTS emails_fts_ad');

      // Must precede the rebuild: 'rebuild' reads body_text straight off the
      // content table, so an unpopulated column would index nothing at all.
      await _backfillEmailBodyText();

      // Restored before the rebuild so no write can slip through unindexed.
      await _createSearchIndexes();

      await _db.execute("INSERT INTO emails_fts(emails_fts) VALUES('rebuild')");
      await _db.execute("INSERT INTO files_fts(files_fts) VALUES('rebuild')");
      await EmailContactRepository(this).backfillFromEmails();
      await _db.execute('PRAGMA user_version = $searchIndexVersion');
      logger.i('AppDatabase: full-text search indexes built');
    } catch (e, stackTrace) {
      logger.e(
        'AppDatabase: failed to build full-text search indexes: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Populates `emails.body_text` for mail stored before the column existed.
  ///
  /// Reads in pages and pulls only the three columns involved — bodies are the
  /// bulk of an archive, and loading every one at once to derive a fourth
  /// column would be a needless multi-gigabyte read.
  ///
  /// Rows where `plain_body` already has content are handled in SQL, since
  /// that is the majority and needs no HTML parsing. Only the HTML-only
  /// remainder — around a third of a real archive — comes back to Dart.
  Future<void> _backfillEmailBodyText() async {
    final copied = await _db.execute(
      "UPDATE emails SET body_text = plain_body "
      "WHERE body_text IS NULL AND plain_body IS NOT NULL AND plain_body <> ''",
    );
    logger.i(
      'AppDatabase: body_text copied from plain_body for '
      '${copied.affectedRows} emails',
    );

    var stripped = 0;
    while (true) {
      final rows = await _db.select(
        "SELECT id, html_body FROM emails "
        "WHERE body_text IS NULL AND html_body IS NOT NULL AND html_body <> '' "
        "LIMIT 200",
      );
      if (rows.isEmpty) break;

      await _db.transaction((tx) async {
        for (final row in rows) {
          final text = bodyTextFrom(null, row['html_body'] as String?);
          // Written even when extraction yields nothing — an empty string
          // still marks the row as processed, and leaving it null would make
          // this loop reselect the same page forever.
          await tx.execute('UPDATE emails SET body_text = ? WHERE id = ?', [
            text,
            row['id'],
          ]);
        }
      });
      stripped += rows.length;
    }

    if (stripped > 0) {
      logger.i(
        'AppDatabase: body_text extracted from HTML for $stripped emails',
      );
    }
  }

  /// Rebuilds `files_embeddings` onto a `(file_id, type)` primary key when it
  /// still has the original `file_id`-only key (with or without the `type`
  /// column added by an earlier version of this migration).
  ///
  /// SQLite can't alter a primary key with `ALTER TABLE`, so this is a
  /// rename-recreate-copy-drop done inside a transaction. Safe to run on
  /// every open: once the key covers `type` this is a single `PRAGMA
  /// table_info` read and nothing else. A single-column key can't hold both
  /// a 'file' and a 'description' embedding for the same file — the second
  /// insert would silently overwrite the first's vector instead of adding a
  /// row — so this has to land before anything writes a non-'file' row.
  Future<void> _migrateFilesEmbeddingsKey() async {
    final info = await _db.select('PRAGMA table_info(files_embeddings)');
    if (info.isEmpty) return;
    Map<String, Object?>? typeColumn;
    for (final row in info) {
      if (row['name'] == 'type') {
        typeColumn = row;
        break;
      }
    }
    final keyedByType = typeColumn != null && (typeColumn['pk'] as int) > 0;
    if (keyedByType) return;

    logger.i(
      'AppDatabase: migrating files_embeddings to a (file_id, type) key',
    );
    final hasTypeColumn = typeColumn != null;
    await _db.transaction((tx) async {
      await tx.execute(
        'ALTER TABLE files_embeddings RENAME TO files_embeddings_old',
      );
      await tx.execute('''
        CREATE TABLE files_embeddings (
          file_id TEXT NOT NULL,
          type TEXT NOT NULL DEFAULT 'file',
          qwen3_vl_embedding BLOB,
          PRIMARY KEY (file_id, type),
          FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
        )
      ''');
      await tx.execute('''
        INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding)
        SELECT file_id, ${hasTypeColumn ? 'type' : "'file'"}, qwen3_vl_embedding
        FROM files_embeddings_old
      ''');
      await tx.execute('DROP TABLE files_embeddings_old');
    });
  }

  /// Rebuilds `emails_embeddings` onto an `(email_id, chunk_index)` primary
  /// key, **discarding every row it held**.
  ///
  /// Discarding is the migration, not a shortcut around one. The stored
  /// vectors are whole-body embeddings, which is precisely what chunking
  /// replaces (§16 of the search plan); but they carry the current
  /// `model_version`, and `model_version` is the only signal
  /// `getEmailsWithMissingEmbeddings` has. Copied forward as chunk 0 they
  /// would read as finished work, and every long email in the archive would
  /// keep its diluted single vector forever — the exact failure the chunking
  /// change exists to fix, made invisible.
  ///
  /// The alternative — bumping [EmbeddingModel.revision] so the rows age out
  /// on their own — is worse here, because that constant is shared with
  /// `files_embeddings`: it would invalidate several thousand image vectors
  /// that nothing about this change touches. The revision stays put and the
  /// mail vectors go.
  ///
  /// SQLite can't alter a primary key with `ALTER TABLE`, so this is a
  /// drop-recreate inside a transaction. Safe to run on every open: once the
  /// key covers `chunk_index` it is a single `PRAGMA table_info` read.
  Future<void> _migrateEmailEmbeddingsToChunks() async {
    final info = await _db.select('PRAGMA table_info(emails_embeddings)');
    if (info.isEmpty) return;
    final chunked = info.any(
      (row) => row['name'] == 'chunk_index' && (row['pk'] as int) > 0,
    );
    if (chunked) return;

    final existing = await _db.select(
      'SELECT COUNT(*) AS n FROM emails_embeddings',
    );
    final discarded = existing.first['n'] as int? ?? 0;
    logger.i(
      'AppDatabase: rebuilding emails_embeddings on (email_id, chunk_index); '
      'discarding $discarded whole-body vectors to be re-embedded as chunks',
    );

    await _db.transaction((tx) async {
      await tx.execute('DROP TABLE emails_embeddings');
      await tx.execute('''
        CREATE TABLE emails_embeddings (
          email_id TEXT NOT NULL,
          chunk_index INTEGER NOT NULL DEFAULT 0,
          qwen3_vl_embedding BLOB,
          model_version TEXT,
          PRIMARY KEY (email_id, chunk_index),
          FOREIGN KEY (email_id) REFERENCES emails(id) ON DELETE CASCADE
        )
      ''');
    });
  }

  /// Columns added to [schemaDDL] after the initial schema shipped.
  ///
  /// The DDL above only runs for a brand-new database, so an existing install
  /// would never see them. Each add is guarded by the table's current columns,
  /// which makes this safe to run on every open — and idempotent, which matters
  /// because `initSchema` is called twice during [create].
  ///
  /// Returns the `table.column` names actually added, so a caller can run a
  /// one-time backfill for exactly the columns that are new.
  Future<Set<String>> _addMissingColumns() async {
    const additions = <String, Map<String, String>>{
      'files': {
        // Inline images in an HTML email are referenced as `cid:<content id>`;
        // without this the client can't tell which attachment a cid names.
        'content_id': 'TEXT',
        // Whether the attachment is part of the message body — a spacer, logo
        // or tracking pixel — rather than something the sender attached.
        'is_inline': 'INTEGER NOT NULL DEFAULT 0',
        'is_favorite': 'INTEGER NOT NULL DEFAULT 0',
        // AI-generated or user-entered description of the file's contents.
        'description': 'TEXT',
        // How many times FileDescriptionIsolate has tried and failed to
        // generate a description for this file (unreadable image, model
        // returned no usable analysis, embedding failed, ...). Without this,
        // a file that can never succeed gets re-selected and retried by
        // getFilesWithMissingDescriptions forever.
        'description_attempts': 'INTEGER NOT NULL DEFAULT 0',
        // The same guard for embeddings. Counts only attempts where the bytes
        // were read and the model rejected them — see
        // DatabaseRepository.maxEmbeddingAttempts, and note that an unreadable
        // file must never land here.
        'embedding_attempts': 'INTEGER NOT NULL DEFAULT 0',
      },
      'albums': {'description': 'TEXT', 'cover_file_id': 'TEXT'},
      // Which embedding pipeline produced the vector in this row. See
      // EmbeddingModel: two vectors are only comparable when built the same
      // way, and nothing downstream can detect otherwise — cosine over
      // incompatible spaces returns plausible numbers, not an error.
      //
      // Nullable on purpose, and that is the migration. Every row already in
      // these tables was written before the loader fix and holds noise; adding
      // the column leaves them NULL, which reads as "unknown pipeline", which
      // the embedding isolates treat as work to redo. The archive re-embeds
      // itself on the next launch with no hand-written DELETE.
      'files_embeddings': {'model_version': 'TEXT'},
      'emails_embeddings': {'model_version': 'TEXT'},
      'emails': {
        // The body text keyword search actually indexes: `plain_body` when the
        // sender provided one, otherwise the HTML body with its markup
        // stripped. A third of the mail in a real archive arrives HTML-only,
        // and indexing `plain_body` alone left every word of it unsearchable.
        //
        // Materialised rather than computed in the FTS declaration because
        // external-content FTS5 reads columns by name — `'rebuild'` issues its
        // own SELECT, so an expression would apply to trigger-written rows and
        // not to rebuilt ones, leaving the index quietly inconsistent with
        // itself.
        'body_text': 'TEXT',
      },
    };

    final added = <String>{};
    for (final table in additions.entries) {
      final existing =
          (await _db.select(
            "PRAGMA table_info(${table.key})",
          )).map((r) => r['name'] as String).toSet();
      for (final column in table.value.entries) {
        if (existing.contains(column.key)) continue;
        logger.i("AppDatabase: adding ${table.key}.${column.key}");
        await _db.execute(
          "ALTER TABLE ${table.key} ADD COLUMN ${column.key} ${column.value}",
        );
        added.add('${table.key}.${column.key}');
      }
    }
    return added;
  }

  /// Marks already-imported attachments that the message body embeds.
  ///
  /// Without this, `is_inline` would only ever be right for mail scanned after
  /// the upgrade, and every archive already on disk would keep pouring its
  /// spacer GIFs and ad banners into the photos module until the user deleted
  /// and re-imported it. The information needed is already in the database —
  /// the stored HTML body says which attachments it references — so this is a
  /// single statement rather than a re-scan.
  ///
  /// Matching mirrors `InlineAttachment`: content id first, then filename for
  /// mail that predates content ids. `instr` rather than `LIKE` because a
  /// filename containing `%` or `_` would otherwise act as a wildcard and flag
  /// unrelated attachments; `lower()` on both sides because senders are
  /// inconsistent about case.
  Future<void> _backfillInlineAttachments() async {
    logger.i("AppDatabase: flagging inline attachments in existing mail...");
    await _db.execute('''
      UPDATE files SET is_inline = 1
      WHERE email_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM emails e
          WHERE e.id = files.email_id
            AND e.html_body IS NOT NULL
            AND e.html_body <> ''
            AND (
              (files.content_id IS NOT NULL AND files.content_id <> ''
                AND instr(lower(e.html_body),
                          'cid:' || lower(files.content_id)) > 0)
              OR instr(lower(e.html_body), 'cid:' || lower(files.name)) > 0
            )
        )
    ''');

    // Embeddings already computed for those images are now dead weight: they
    // can never be reached through the photos module and only add spacer GIFs
    // and ad banners to similarity results. Dropping them is safe — an
    // embedding is a derived cache, and the isolate recomputes anything still
    // eligible — but it is deliberately part of the same one-time pass so a
    // pre-existing index converges on the same contents a fresh one would have.
    final cleared = await _db.select('''
      SELECT COUNT(*) AS c FROM files_embeddings
      WHERE file_id IN (SELECT id FROM files WHERE is_inline = 1)
    ''');
    final count = cleared.isEmpty ? 0 : (cleared.first['c'] as int? ?? 0);
    if (count > 0) {
      logger.i("AppDatabase: dropping $count embeddings for inline images");
      await _db.execute('''
        DELETE FROM files_embeddings
        WHERE file_id IN (SELECT id FROM files WHERE is_inline = 1)
      ''');
    }
  }

  static Future<void> _seedAichatSkills(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final skills = [
      {
        'trigger': '/summarize',
        'name': 'Summarize',
        'description': 'Condense content into a concise bullet-point summary.',
        'system_prompt':
            'You are a summarization assistant. Summarize the following content concisely using bullet points. Be brief and capture only the key points.',
      },
      {
        'trigger': '/analyze',
        'name': 'Analyze',
        'description': 'Deep analysis of themes, patterns, and key insights.',
        'system_prompt':
            'You are an analytical assistant. Analyze the following content in depth. Identify themes, patterns, key insights, and notable details. Structure your response clearly.',
      },
      {
        'trigger': '/translate',
        'name': 'Translate',
        'description': 'Translate text to English.',
        'system_prompt':
            'You are a translation assistant. Translate the user\'s message to English. Output only the translation with no additional commentary.',
      },
      {
        'trigger': '/explain',
        'name': 'Explain',
        'description': 'Explain a concept or text in simple terms.',
        'system_prompt':
            'You are a teacher. Explain the following in simple, clear terms that anyone can understand. Use examples where helpful.',
      },
      {
        'trigger': '/rewrite',
        'name': 'Rewrite',
        'description': 'Rewrite text to be clearer and more professional.',
        'system_prompt':
            'You are a professional editor. Rewrite the following text to be clearer, more concise, and more professional while preserving the original meaning. Output only the rewritten text.',
      },
    ];
    for (final s in skills) {
      await db.execute(
        'INSERT OR IGNORE INTO aichat_skills (id, trigger, name, description, system_prompt, enabled, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, 1, ?, ?)',
        [
          const Uuid().v4(),
          s['trigger'],
          s['name'],
          s['description'],
          s['system_prompt'],
          now,
          now,
        ],
      );
    }
  }

  static Future<void> _seedAichatModels(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final models = [
      // ── Local GGUF models ──────────────────────────────────────────────────
      // gemma4:12b is the default chat model — no longer bundled with the app;
      // ModelDownloadManager downloads it automatically on first startup and
      // enables this row once the download completes.
      {
        'id': const Uuid().v4(),
        'alias': 'gemma4:12b',
        'group': 'local',
        'name': 'Gemma 4 12B',
        'type': 'gguf',
        'file': 'gemma-4-12B-it-Q4_0.gguf',
        'mmproj': 'mmproj-gemma-4-12B-it-Q8_0.gguf',
        'hf_repo': 'ggml-org/gemma-4-12B-it-GGUF',
        'chat_handler': 'Gemma4ChatHandler',
        'enabled': 0,
      },
      // Default embedding model (text + image) used for file/photo search.
      // Not chat-selectable (group isn't in AichatPage's dropdown groups) —
      // ModelDownloadManager downloads and enables it automatically at startup.
      {
        'id': const Uuid().v4(),
        'alias': 'qwen3-vl-embedding:2b',
        'group': 'embedding',
        'name': 'Qwen 3 VL Embedding 2B',
        'type': 'transformers',
        'file': null,
        'mmproj': null,
        'hf_repo': 'Qwen/Qwen3-VL-Embedding-2B',
        'chat_handler': null,
        'enabled': 0,
      },
      // Downloadable local models — disabled until the user downloads them
      {
        'id': const Uuid().v4(),
        'alias': 'qwen3:4b',
        'group': 'local',
        'name': 'Qwen 3 4B',
        'type': 'gguf',
        'description':
            'Designed for strong reasoning and coding capabilities, by Alibaba Clouds Qwen team.',
        'file': 'Qwen_Qwen3.5-4B-Q3_K_L.gguf',
        'mmproj': 'mmproj-Qwen_Qwen3.5-4B-f16.gguf',
        'hf_repo': 'bartowski/Qwen_Qwen3.5-4B-GGUF',
        'chat_handler': null,
      },
      {
        'id': const Uuid().v4(),
        'alias': 'llama3.2:3b',
        'group': 'local',
        'name': 'Meta Llama 3.2 3B',
        'type': 'gguf',
        'description':
            'a lightweight, text-in/text-out language model released by Meta',
        'file': 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
        'mmproj': null,
        'hf_repo': 'bartowski/Llama-3.2-3B-Instruct-GGUF',
        'chat_handler': null,
      },
      {
        'id': const Uuid().v4(),
        'alias': 'phi4',
        'group': 'local',
        'name': 'Microsoft Phi-4',
        'type': 'gguf',
        'description':
            'designed by Microsoft to excel at complex reasoning—particularly in math, science, and coding',
        'file': 'phi4-mm-Q4_K_M.gguf',
        'mmproj': 'mmproj-phi4-mm-f16.gguf',
        'hf_repo': 'Swicked86/phi4-mm-gguf',
        'chat_handler': 'Phi3VisionChatHandler',
      },
      // ── Gemini ────────────────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'gemini-3.5-flash',
        'group': 'gemini',
        'name': 'Gemini 3.5 Flash',
        'description':
            'Frontier-level intelligence optimized for real-world tasks at a higher speed and lower cost.',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'gemini-3.1-pro-preview',
        'group': 'gemini',
        'name': 'Gemini 3.1 Pro',
        'description':
            'Provides better thinking, improved token efficiency, and a more grounded, factually consistent experience.',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'gemini-3.1-flash-image',
        'group': 'gemini',
        'name': 'Nano Banana 2',
        'description':
            'Provides high-quality image generation and conversational editing',
        'type': 'api',
      },
      // ── Claude ────────────────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'claude-fabel-5',
        'group': 'claude',
        'name': 'Fabel 5',
        'description': 'Next-generation intelligence for long-running agents',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'claude-opus-4-8',
        'group': 'claude',
        'name': 'Opus 4.8',
        'description': 'For complex agentic coding and enterprise work',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'claude-sonnet-5',
        'group': 'claude',
        'name': 'Sonnet 5',
        'description': 'The best combination of speed and intelligence',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'claude-haiku-4-5',
        'group': 'claude',
        'name': 'Haiku 4.5',
        'description': 'The fastest model with near-frontier intelligence',
        'type': 'api',
      },
      // ── OpenAI ────────────────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'gpt-5.5',
        'group': 'openai',
        'name': 'GPT-5.5',
        'description':
            'A new class of intelligence for coding and professional work.',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'gpt-5.4',
        'group': 'openai',
        'name': 'GPT-5.4',
        'description':
            'A more affordable model for coding and professional work.',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'gpt-5.4-mini',
        'group': 'openai',
        'name': 'GPT-5.4 mini',
        'description':
            'Our strongest mini model yet for coding, computer use, and subagents',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'gpt-image-2',
        'group': 'openai',
        'name': 'GPT Image 2',
        'description': 'State-of-the-art image generation model',
        'type': 'api',
      },
      // ── Grok ──────────────────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'grok-4.3',
        'group': 'grok',
        'name': 'Grok 4.3',
        'description':
            'For everything except code, audio, image, and video. The most intelligent and fastest model we’ve built.',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'grok-imagine-image-quality',
        'group': 'grok',
        'name': 'Imaging Generation',
        'description':
            'Generate images from text prompts with configurable aspect ratio, resolution, and count.',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'grok-imagine-video-1.5',
        'group': 'grok',
        'name': 'Image-to-Video',
        'description':
            'Animate a still image with a text prompt. The source image becomes the first frame.',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'grok-imagine-image-editing',
        'group': 'grok',
        'name': 'Image Editing',
        'description':
            'Edit images with natural language. Supports up to 3 reference images per request.',
        'type': 'api',
      },
      // ── Ollama placeholder ────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'ollama',
        'group': 'ollama',
        'name': 'Ollama',
        'type': 'ollama',
        'base_url': null,
      },
    ];
    for (final m in models) {
      final enabled = (m['enabled'] as int?) ?? 0;
      await db.execute(
        'INSERT OR IGNORE INTO aichat_models (id, alias, "group", name, description, file, mmproj, hf_repo, chat_handler, type, base_url, enabled, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          m['id'],
          m['alias'],
          m['group'],
          m['name'],
          m['description'],
          m['file'],
          m['mmproj'],
          m['hf_repo'],
          m['chat_handler'],
          m['type'],
          m['base_url'],
          enabled,
          now,
          now,
        ],
      );
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
      password TEXT NOT NULL
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
      local_path TEXT,
      content_id TEXT,
      is_inline INTEGER NOT NULL DEFAULT 0,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      description TEXT
    );
    ''',
    '''
    CREATE INDEX IF NOT EXISTS idx_files_active_date
      ON files (is_deleted, is_inline, date_created);
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
      name TEXT NOT NULL,
      description TEXT,
      cover_file_id TEXT
    );
    ''',
    // file_tags
    '''
    CREATE TABLE IF NOT EXISTS file_tags (
      file_id TEXT NOT NULL,
      tag TEXT NOT NULL,
      PRIMARY KEY (file_id, tag),
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    ''',
    '''
    CREATE INDEX IF NOT EXISTS idx_file_tags_tag ON file_tags(tag);
    ''',
    // album_files
    '''
    CREATE TABLE IF NOT EXISTS album_files (
      album_id TEXT NOT NULL,
      file_id TEXT NOT NULL,
      PRIMARY KEY (album_id, file_id),
      FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE,
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    ''',
    // files_embeddings
    //
    // Keyed on (file_id, type) rather than file_id alone: a file needs one
    // embedding row per kind of thing it was computed from — the image
    // itself ('file'), a generated description's text ('description'), and
    // eventually PDF RAG chunks ('chunk') — all sharing the same vector
    // column so similarity search can scan across (or filter within) them.
    '''
    CREATE TABLE IF NOT EXISTS files_embeddings (
      file_id TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'file',
      qwen3_vl_embedding BLOB,
      model_version TEXT,
      PRIMARY KEY (file_id, type),
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    ''',
    // file_tags
    '''
    CREATE TABLE IF NOT EXISTS file_tags (
      file_id TEXT NOT NULL,
      tag TEXT NOT NULL,
      PRIMARY KEY (file_id, tag),
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    ''',
    '''
    CREATE INDEX IF NOT EXISTS file_tags_tag_idx ON file_tags (tag);
    ''',
    // file_landmarks
    '''
    CREATE TABLE IF NOT EXISTS file_landmarks (
      file_id TEXT NOT NULL,
      landmark TEXT NOT NULL,
      PRIMARY KEY (file_id, landmark),
      FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    ''',
    '''
    CREATE INDEX IF NOT EXISTS file_landmarks_landmark_idx ON file_landmarks (landmark);
    ''',
    // emails_embeddings
    '''
    CREATE TABLE IF NOT EXISTS emails_embeddings (
      email_id TEXT NOT NULL,
      chunk_index INTEGER NOT NULL DEFAULT 0,
      qwen3_vl_embedding BLOB,
      model_version TEXT,
      PRIMARY KEY (email_id, chunk_index),
      FOREIGN KEY (email_id) REFERENCES emails(id) ON DELETE CASCADE
    );
    ''',
    // providers
    '''
    CREATE TABLE IF NOT EXISTS providers (
      service TEXT PRIMARY KEY,
      client_id TEXT NOT NULL,
      client_secret TEXT NOT NULL,
      api_key TEXT NOT NULL,
      permissions TEXT,
      type TEXT NOT NULL DEFAULT 'collection'
    );
    ''',
    // aichat_conversations
    '''
    CREATE TABLE IF NOT EXISTS aichat_conversations (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      model TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    ''',
    // aichat_conversation_history
    '''
    CREATE TABLE IF NOT EXISTS aichat_conversation_history (
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      token_count INTEGER,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (conversation_id) REFERENCES aichat_conversations(id) ON DELETE CASCADE
    );
    ''',
    // aichat_models
    _aichatModelsDDL,
    // aichat_skills
    _aichatSkillsDDL,
  ];

  static const String _aichatModelsDDL = '''
    CREATE TABLE IF NOT EXISTS aichat_models (
      id TEXT PRIMARY KEY,
      alias TEXT NOT NULL,
      "group" TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      file TEXT,
      mmproj TEXT,
      hf_repo TEXT,
      chat_handler TEXT,
      type TEXT NOT NULL DEFAULT 'api',
      base_url TEXT,
      enabled INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
  ''';

  static const String _aichatSkillsDDL = '''
    CREATE TABLE IF NOT EXISTS aichat_skills (
      id TEXT PRIMARY KEY,
      trigger TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      description TEXT,
      system_prompt TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
  ''';
}
