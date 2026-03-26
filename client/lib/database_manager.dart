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
  String? storagePath;
  AppDatabase? appDatabase;
  DbIsolateWriterClient? _writerIsolateClient;
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

      // macOS path_provider quirk: ensure the directory matches our realm name if on develop
      if (io.Platform.isMacOS && AppConstants.realmName.endsWith('.dev')) {
        if (!supportPath.path.endsWith(AppConstants.realmName)) {
          // Adjust path to use the .dev version
          final parent = supportPath.parent.path;
          supportPath = io.Directory(p.join(parent, AppConstants.realmName));
        }
      }
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

    // start database repository
    _repository = DatabaseRepository(appDatabase!);

    // start writer isolate
    await _startWriterIsolate(appDatabase!, path);

    // start scanners
    await _startScanners();

    // start embedding isolate
    await _startEmbeddingIsolate(path);

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

  Future<void> _startEmbeddingIsolate(String storagePath) async {
    _embeddingIsolate = EmbeddingIsolate();
    await _embeddingIsolate!.start(
      storagePath,
      AppConstants.dbName,
      _writerPort!,
      RootIsolateToken.instance!,
    );
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
  ],
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
  int get schemaVersion => 12;

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
      },
      beforeOpen: (OpeningDetails details) async {
        // WAL (Write-Ahead Logging) allows the DbIsolateWriter to bulk-write
        // while the main connection reads concurrently. Without WAL, a write
        // transaction blocks ALL readers at the SQLite level, even if they're
        // on separate connections/isolates.
        //
        // These PRAGMAs are connection-scoped and safe to re-apply on every open.
        await customStatement('PRAGMA journal_mode=WAL;');

        // Allow up to 5 seconds of retry before returning SQLITE_BUSY.
        // Prevents sporadic errors when the writer and reader briefly contend
        // (e.g. during PST bulk import).
        await customStatement('PRAGMA busy_timeout=5000;');

        logger.i('Database opened: journal_mode=WAL, busy_timeout=5000ms');
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

      return Future(() => appsAdded);
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
  try {
    sqlite3.loadSqliteVectorExtension();
    AppLogger(null).d('sqlite_vector extension loaded');
  } catch (e) {
    AppLogger(
      null,
    ).w('sqlite_vector not loaded (vector search unavailable): $e');
  }
  return sqlite3;
}

LazyDatabase _openConnection(String? path, String? name, bool useMemoryDb) {
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
      sqlite3.tempDirectory = (await getTemporaryDirectory()).path;

      AppLogger(null).i("Opening Database | $path");
      // createInBackground moves all SQLite I/O to a dedicated background
      // isolate managed by Drift. This prevents any DB query from blocking
      // frames on the main UI thread, fixing jank during email queries and
      // PST imports.
      return NativeDatabase.createInBackground(
        file,
        logStatements: false,
        setup: (db) {
          db.execute('PRAGMA busy_timeout=5000;');
          db.execute('PRAGMA journal_mode=WAL;');
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
