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
import 'package:mydatatools/custom_path_provider.dart';
import 'package:mydatatools/modules/files/services/file_upsert_service.dart';
import 'package:mydatatools/modules/files/services/folder_upsert_service.dart';
import 'package:mydatatools/modules/files/services/batch_file_upsert_service.dart';
import 'package:mydatatools/modules/files/services/cleanup_deleted_files_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';
import 'package:mydatatools/models/tables/album.dart';
import 'package:mydatatools/models/tables/app.dart';
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/converters/string_array_convertor.dart';
import 'package:mydatatools/models/tables/converters/float_list_converter.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/file_embedding.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/models/tables/provider.dart';
import 'package:flutter/services.dart';
import 'package:mydatatools/modules/files/services/embedding_isolate.dart';
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

  /// Flag to skip loading native extensions (for testing environments)
  static bool skipExtensionLoading = false;

  /// Flag to indicate if the app is running in a test environment
  static bool isTesting = io.Platform.environment.containsKey('FLUTTER_TEST');
  String? storagePath;
  AppDatabase? appDatabase;
  DbIsolateWriterClient? _writerIsolateClient;
  ReceivePort? _testWriterPort;
  StreamSubscription? _testWriterSubscription;
  SendPort? _writerPort;
  EmbeddingIsolate? _embeddingIsolate;
  DatabaseRepository? _repository;
  final AppLogger logger = AppLogger(null);

  DatabaseManager._();

  /// Returns the [DatabaseRepository] instance
  DatabaseRepository? get repository {
    return _repository;
  }

  DbIsolateWriterClient? get writerIsolateClient {
    return _writerIsolateClient;
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

  /// Initializes the database, repository, writer isolate, and scanners
  Future<AppDatabase> initializeDatabase() async {
    io.File file = io.File(await _getConfigPath());
    var config = jsonDecode(file.readAsStringSync());
    storagePath = config['path'];
    String path = storagePath!;

    // Ensure the global appDataDirectory subject has the value
    MainApp.appDataDirectory.add(path);

    // Override application support path globally so aichat, google_fonts, etc. use the selected storagePath
    if (PathProviderPlatform.instance is! CustomPathProviderPlatform) {
      PathProviderPlatform.instance = CustomPathProviderPlatform(
        PathProviderPlatform.instance,
        path,
      );
    }

    // start database
    appDatabase = await _openDatabase(path);

    // Explicitly enforce WAL mode before spawning background isolates.
    // This guarantees the database acquires the initial EXCLUSIVE lock
    // and converts to WAL mode without contention from background threads.
    await appDatabase!.customStatement('PRAGMA journal_mode=WAL;');

    // start database repository
    _repository = DatabaseRepository(appDatabase!);
 
    if (isTesting) {
      _startTestWriterPort(appDatabase!);
    } else {
      // start writer isolate
      await _startWriterIsolate(appDatabase!, path);

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
      if (err is io.FileSystemException) {
        rethrow;
      }
      throw Exception(err);
    }
  }

  void _startTestWriterPort(AppDatabase db) {
    _testWriterSubscription?.cancel();
    _testWriterPort?.close();
    
    _testWriterPort = ReceivePort();
    _writerPort = _testWriterPort!.sendPort;
    _testWriterSubscription = _testWriterPort!.listen((data) async {
      if (data is! Map) return;
      SendPort? replyTo = data['replyTo'] as SendPort?;
      try {
        if (data['type'] == 'file') {
          await FileUpsertService.instance.invoke(FileUpsertServiceCommand(data['file'] as File, db));
          replyTo?.send({'status': 'ok'});
        } else if (data['type'] == 'batch_file') {
          await BatchFileUpsertService.instance.invoke(BatchFileUpsertServiceCommand((data['files'] as List).cast<File>(), db));
          replyTo?.send({'status': 'ok'});
        } else if (data['type'] == 'folder') {
          await FolderUpsertService.instance.invoke(FolderUpsertServiceCommand(data['folder'] as Folder, db));
          replyTo?.send({'status': 'ok'});
        } else if (data['type'] == 'cleanup_deleted') {
          await CleanupDeletedFilesService.instance.invoke(CleanupDeletedFilesServiceCommand(
            data['collectionId'] as String,
            data['path'] as String,
            data['scanStartTime'] as DateTime,
            db,
            recursive: data['recursive'] ?? true,
          ));
          replyTo?.send({'status': 'ok'});
        }
      } catch (e) {
        logger.e("TestWriterPort error: $e");
        replyTo?.send({'status': 'error', 'message': e.toString()});
      }
    });
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

  Future<void> _startEmbeddingIsolate(String storagePath) async {
    _embeddingIsolate = EmbeddingIsolate();
    await _embeddingIsolate!.start(
      storagePath,
      AppConstants.dbName,
      _writerPort!,
      RootIsolateToken.instance!,
    );
  }

  void dispose() {
    _testWriterSubscription?.cancel();
    _testWriterPort?.close();
    _testWriterPort = null;
    _testWriterSubscription = null;

    _writerIsolateClient?.stop();
    _writerIsolateClient = null;

    _embeddingIsolate?.stop();
    _embeddingIsolate = null;
    
    appDatabase?.close();
    appDatabase = null;
    _writerPort = null;
    _repository = null;
    isInitializedNotifier.value = false;
  }

  /// Returns the [SendPort] for the writer isolate
  Future<SendPort> get writerPort async {
    if (_writerPort == null) {
      throw Exception(
        "Unkown error initializing Database and/or writer isolate",
      );
    }
    return Future.value(_writerPort!);
  }

  /// Stop helper to be called from app shell
  /// Stops the database writer isolate
  Future<void> stopDbWriterIsolate() async {
    try {
      if (_testWriterSubscription != null) {
        await _testWriterSubscription!.cancel();
        _testWriterPort?.close();
        _testWriterSubscription = null;
        _testWriterPort = null;
      }
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
  tables: [
    Apps,
    AppUsers,
    Collections,
    Emails,
    EmailFolders,
    Files,
    Folders,
    Albums,
    FilesEmbeddings,
    Providers,
  ],
)
class AppDatabase extends _$AppDatabase {
  final AppLogger logger = AppLogger(null);

  AppDatabase([
    QueryExecutor? executor,
    String? path,
    String? name,
    bool useMemoryDb = false,
    bool inBackground = true,
  ]) : super(executor ?? _openConnection(path, name, useMemoryDb, inBackground));

  String? path;
  String? name;

  @override
  int get schemaVersion => 16;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        logger.i("Creating all Tables");
        await m.createAll();
        logger.i("Load initial data");
        await _loadInitialData(m);
        // Initialize the vector index for qwen3_8b embeddings (2048-dim Float32)
        logger.i("Initializing vector index for files_embeddings");
        await _initVectorIndex();
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
        if (from < 4) {
          logger.i(
            "Upgrade to v4: Adding files_embeddings table and vector index",
          );
          await m.createTable(filesEmbeddings);
          await _initVectorIndex();
        }
        if (from < 5) {
          logger.i(
            "Upgrade to v5: Re-initializing vector index for sqlite_vector",
          );
          await _initVectorIndex();
        }
        if (from < 6) {
          logger.i(
            "Upgrade to v6: Adding EmailFolders table and folder/metadata columns to Emails",
          );
          await m.createTable(emailFolders);
          await m.addColumn(emails, emails.folderId);
          await m.addColumn(emails, emails.messageId);
          await m.addColumn(emails, emails.threadId);
          await m.addColumn(emails, emails.isRead);
          await m.addColumn(emails, emails.hasAttachments);
        }
        if (from < 7) {
          logger.i("Upgrade to v7: Adding emailId column to Files table");
          await m.addColumn(files, files.emailId);
        }
        if (from < 10) {
          logger.i("Upgrade to v10: Adding uid column to Emails table");
          try {
            await m.addColumn(emails, emails.uid);
          } catch (e) {
            if (e.toString().contains('duplicate column name')) {
              logger.w("uid column already exists in Emails table, skipping.");
            } else {
              rethrow;
            }
          }
        }
        if (from < 11) {
          logger.i(
            "Upgrade to v11: Adding composite indexes for faster email lookups",
          );
          try {
            await m.createIndex(
              Index(
                'email_folderid_idx',
                'CREATE INDEX email_folderid_idx ON emails (folder_id)',
              ),
            );
            await m.createIndex(
              Index(
                'email_comp_sync_idx',
                'CREATE INDEX email_comp_sync_idx ON emails (collection_id, folder_id, date)',
              ),
            );
          } catch (e) {
            logger.w("Indexes already exist in Emails table, skipping.");
          }
        }
        if (from < 12) {
          logger.i(
            'Upgrade to v12: Adding localCopyPath to Collections '
            'and migrating files/folders to relative paths',
          );
          await m.addColumn(collections, collections.localCopyPath);

          // Data migration using raw SQL — the Drift table accessors are not
          // available inside onUpgrade (m.database is GeneratedDatabase, not
          // AppDatabase). We use customStatement / m.database.customSelect
          // to do the data work safely.
          //
          // Step 1: For each collection, set local_copy_path = path.
          await m.database.customStatement(
            'UPDATE collections SET local_copy_path = path WHERE path IS NOT NULL AND path != \'\'',
          );

          // Step 2: Strip absolute prefix from files.path, files.parent.
          // We do this in Dart by loading rows and updating them.
          final colRows =
              await m.database
                  .customSelect(
                    'SELECT id, path FROM collections WHERE path IS NOT NULL AND path != \'\'',
                  )
                  .get();

          for (final colRow in colRows) {
            final colId = colRow.read<String>('id');
            final root = colRow.read<String>('path');
            final prefix = root.endsWith('/') ? root : '$root/';

            // Update files — only migrate rows whose path still contains
            // the absolute prefix (not yet migrated). Rows already using
            // a relative path are left untouched.
            final fileRows =
                await m.database
                    .customSelect(
                      'SELECT id, path, parent FROM files WHERE collection_id = ? AND path LIKE ?',
                      variables: [
                        Variable.withString(colId),
                        Variable.withString('$prefix%'),
                      ],
                    )
                    .get();
            for (final row in fileRows) {
              final oldId = row.read<String>('id');
              final oldPath = row.read<String>('path');
              final oldParent = row.read<String>('parent');
              final relPath = oldPath.substring(prefix.length);
              final relParent =
                  oldParent.startsWith(prefix)
                      ? oldParent.substring(prefix.length)
                      : (oldParent == root ? '' : oldParent);
              final newId = '$colId:$relPath';
              if (newId == oldId) continue; // already migrated, skip
              // Delete any conflicting row with the new id first so we don't
              // hit the UNIQUE constraint.
              await m.database.customStatement(
                'DELETE FROM files WHERE id = ? AND id != ?',
                [newId, oldId],
              );
              await m.database.customStatement(
                'UPDATE files SET id = ?, path = ?, parent = ? WHERE id = ?',
                [newId, relPath, relParent, oldId],
              );
            }

            // Update folders — same idempotent logic.
            final folderRows =
                await m.database
                    .customSelect(
                      'SELECT id, path, parent FROM folders WHERE collection_id = ? AND path LIKE ?',
                      variables: [
                        Variable.withString(colId),
                        Variable.withString('$prefix%'),
                      ],
                    )
                    .get();
            for (final row in folderRows) {
              final oldId = row.read<String>('id');
              final oldPath = row.read<String>('path');
              final oldParent = row.read<String>('parent');
              final relPath = oldPath.substring(prefix.length);
              final relParent =
                  oldParent.startsWith(prefix)
                      ? oldParent.substring(prefix.length)
                      : (oldParent == root ? '' : oldParent);
              final newId = '$colId:$relPath';
              if (newId == oldId) continue;
              await m.database.customStatement(
                'DELETE FROM folders WHERE id = ? AND id != ?',
                [newId, oldId],
              );
              await m.database.customStatement(
                'UPDATE folders SET id = ?, path = ?, parent = ? WHERE id = ?',
                [newId, relPath, relParent, oldId],
              );
            }
          }
          logger.i('v12 data migration complete');
        }
        if (from < 13) {
          logger.i(
            'Upgrade to v13: Mark Google OAuth collections for PKCE re-auth',
          );
          // Tokens obtained with the old Authorization Code Grant (which
          // embedded client_secret) won't refresh without the secret. Flag
          // every Google collection so the UI prompts re-authentication
          // through the new PKCE flow.
          await m.database.customStatement(
            "UPDATE collections SET needs_re_auth = 1 "
            "WHERE oauth_service = 'google'",
          );
          logger.i('v13 migration complete');
        }
        if (from < 14) {
          logger.i(
            'Upgrade to v14: Rename download_attachments to download_local_copy',
          );
          await m.renameColumn(
            collections,
            'download_attachments',
            collections.downloadLocalCopy,
          );
          logger.i('v14 migration complete');
        }
        if (from < 15) {
          logger.i(
            'Upgrade to v15: Adding localPath to Files',
          );
          try {
            await m.database.customStatement(
              'ALTER TABLE files ADD COLUMN local_path TEXT',
            );
          } catch (e) {
            if (e.toString().contains('duplicate column name')) {
              logger.w("local_path column already exists in Files table, skipping.");
            } else {
              rethrow;
            }
          }
          logger.i('v15 migration complete');
        }
        if (from < 16) {
          logger.i(
            'Upgrade to v16: Adding Providers table',
          );
          await m.createTable(providers);
          logger.i('v16 migration complete');
        }
      },
      beforeOpen: (OpeningDetails details) async {
        // PRAGMAs (journal_mode, busy_timeout, cache_size, mmap_size, etc.)
        // are configured in the NativeDatabase setup callback in _openConnection.
        // Do NOT set them here — this runs on ALL connections including the
        // read-only embedding isolate, and PRAGMA journal_mode=WAL is a write
        // operation that can trigger lock contention during scanning.
        logger.i('Database opened (schema v${details.versionNow})');
      },
    );
  }

  /// Initializes the sqlite_vector ANN index on the qwen3_8b_embedding column.
  ///
  /// sqlite_vector uses a regular BLOB column + a side-car index created via
  /// `vector_init()`. This is different from the old vec0 virtual table.
  /// The index persists in the database file after first creation.
  ///
  /// Gracefully no-ops if the extension is not loaded (tests without native lib).
  Future<void> _initVectorIndex() async {
    try {
      await customStatement(
        "SELECT vector_init('files_embeddings', 'qwen3_8b_embedding', 'type=FLOAT32,dimension=2048')",
      );
    } catch (e) {
      logger.w('Could not initialize vector index (extension not loaded?): $e');
    }
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

      return appsAdded;
    } catch (err) {
      logger.e(err);
      rethrow;
    }
  }
}

/// Returns a configured [Sqlite3] instance with the sqlite_vector extension
/// loaded. Used as the `sqlite3:` factory for [NativeDatabase].
///
/// sqlite_vector handles bundling the native library for all platforms
/// automatically via Dart native assets — no manual dylib copying needed.
///
/// Gracefully no-ops (with a warning) if the extension fails to load so
/// dev/test builds without native assets still work.
Sqlite3 _loadExtensions() {
  if (DatabaseManager.skipExtensionLoading) {
    return sqlite3;
  }
  try {
    sqlite3.loadSqliteVectorExtension();
    AppLogger(null).d('sqlite_vector extension loaded');
  } catch (e) {
    // In tests, the native assets might not be available. We log a warning
    // instead of throwing to allow dev/test flows to continue without vectors.
    AppLogger(null).w(
      'sqlite_vector not loaded (vector search unavailable): $e',
    );
  }
  return sqlite3;
}

LazyDatabase _openConnection(String? path, String? name, bool useMemoryDb, bool inBackground) {
  if (!useMemoryDb && (path == null || name == null)) {
    throw ("Path or Name not provided, can not start scanner");
  }

  // the LazyDatabase util lets us find the right location for the file async.
  return LazyDatabase(() async {
    AppLogger(null).i('Initialize Database | path=$path');

    if (!useMemoryDb) {
      // check app startup initialization
      io.File file = io.File(p.join(path!, 'data', name));
      path = file.path;

      // Make sqlite3 pick a more suitable location for temporary files - the
      // one from the system may be inaccessible due to ios/mac app sandbox.
      if (!DatabaseManager.isTesting) {
        sqlite3.tempDirectory = (await getTemporaryDirectory()).path;
      }

      AppLogger(null).i("Opening Database | $path");
      // In tests, avoid createInBackground to bypass FFI/isolate callback issues
      // Also avoid it if inBackground is false (e.g., when already running inside an isolate)
      if (DatabaseManager.isTesting || !inBackground) {
        return NativeDatabase(
          file,
          logStatements: false,
          setup: (db) {
            db.execute('PRAGMA busy_timeout=15000;');
            db.execute('PRAGMA journal_mode=WAL;');
            // Disable auto-checkpointing on the writer isolate's connection.
            // WAL auto-checkpoint triggers an exclusive lock on the main DB
            // file which competes with the main thread's connection during
            // heavy scanning. Let the main thread handle checkpoints instead.
            db.execute('PRAGMA wal_autocheckpoint=0;');
            // Performance: 20MB page cache, 256MB memory-mapped I/O,
            // NORMAL sync (safe with WAL), temp tables in RAM.
            db.execute('PRAGMA cache_size=-20000;');
            db.execute('PRAGMA mmap_size=268435456;');
            db.execute('PRAGMA synchronous=NORMAL;');
            db.execute('PRAGMA temp_store=MEMORY;');
          },
          sqlite3: _loadExtensions,
        );
      }
      
      // createInBackground moves all SQLite I/O to a dedicated background
      // isolate managed by Drift. This prevents any DB query from blocking
      // frames on the main UI thread, fixing jank during email queries and
      // PST imports.
      return NativeDatabase.createInBackground(
        file,
        logStatements: false,
        setup: (db) {
          db.execute('PRAGMA busy_timeout=15000;');
          db.execute('PRAGMA journal_mode=WAL;');
          // Increase auto-checkpoint threshold to reduce frequency of
          // checkpoint-driven write lock contention. Default is 1000 pages;
          // 4000 pages (~16MB WAL) gives the writer isolate more breathing
          // room during heavy scanning.
          db.execute('PRAGMA wal_autocheckpoint=4000;');
          // Performance: 20MB page cache, 256MB memory-mapped I/O,
          // NORMAL sync (safe with WAL), temp tables in RAM.
          db.execute('PRAGMA cache_size=-20000;');
          db.execute('PRAGMA mmap_size=268435456;');
          db.execute('PRAGMA synchronous=NORMAL;');
          db.execute('PRAGMA temp_store=MEMORY;');
        },
        sqlite3: _loadExtensions,
      );
    } else {
      return NativeDatabase.memory(
        logStatements: false,
        cachePreparedStatements: false,
        sqlite3: _loadExtensions,
      );
    }
  });
}
