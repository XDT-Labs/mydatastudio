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
        print(
          "DEBUG testPathSupportsWal: Path does not support WAL mode (returned: $mode)",
        );
        return false;
      }
      return true;
    } catch (e) {
      // Clean up test files if created.
      print("DEBUG testPathSupportsWal failed: $e");
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

    if (!isTesting) {
      // start scanners
      await _startScanners();

      // start embedding isolate
      await _startEmbeddingIsolate(appDatabase!.path!);
    }

    isInitializedNotifier.value = true;
    return appDatabase!;
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

  int get schemaVersion => 18;

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
    print("DEBUG AppDatabase.create: opening db at ${dbFile.path}");
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
          column: 'qwen3_8b_embedding',
          dimension: 2048,
        ),
        SqliteVectorIndex(
          table: 'files_embeddings',
          column: 'siglip2_embedding',
          dimension: 1152,
        ),
      ],
    );

    // Step 1: Open without vector index to let initSchema create/migrate all tables
    // (including files_embeddings) before vector_init is called.
    Database db = await Database.open(
      dbFile.path,
      extensions: [SqliteVectorExtension()],
    );
    final bootstrapDb = AppDatabase(db);
    bootstrapDb.path = finalDbDir;
    bootstrapDb.name = dbName;
    await bootstrapDb.initSchema();
    await db.close();

    // Step 2: Reopen with vector indexes now that files_embeddings is migrated.
    db = await Database.open(dbFile.path, extensions: [vectorExtension]);

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
    } else {
      // Schema migration: Check if siglip2_embedding exists or if qwen3_8b_embedding is NOT NULL
      try {
        final columns = await _db.select(
          "PRAGMA table_info(files_embeddings);",
        );
        final hasSiglip2 = columns.any((c) => c['name'] == 'siglip2_embedding');
        bool isQwenNotNull = false;
        for (final c in columns) {
          if (c['name'] == 'qwen3_8b_embedding') {
            if (c['notnull'] == 1) {
              isQwenNotNull = true;
            }
            break;
          }
        }

        if (!hasSiglip2 || isQwenNotNull) {
          logger.i(
            "AppDatabase: Re-creating files_embeddings table for new schema...",
          );
          await _db.execute("DROP TABLE IF EXISTS files_embeddings;");
          await _db.execute('''
            CREATE TABLE files_embeddings (
              file_id TEXT PRIMARY KEY,
              qwen3_8b_embedding BLOB,
              siglip2_embedding BLOB,
              FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
            );
          ''');
        }
      } catch (e) {
        logger.e("AppDatabase: Migration of files_embeddings table failed: $e");
      }

      // v17: add aichat tables if missing
      try {
        final aichatTables = await _db.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='aichat_conversations'",
        );
        if (aichatTables.isEmpty) {
          logger.i(
            "AppDatabase: Creating aichat_conversations and aichat_conversation_history tables...",
          );
          await _db.execute('''
            CREATE TABLE IF NOT EXISTS aichat_conversations (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              model TEXT,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            );
          ''');
          await _db.execute('''
            CREATE TABLE IF NOT EXISTS aichat_conversation_history (
              id TEXT PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              role TEXT NOT NULL,
              content TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              FOREIGN KEY (conversation_id) REFERENCES aichat_conversations(id) ON DELETE CASCADE
            );
          ''');
        }
      } catch (e) {
        logger.e("AppDatabase: Migration of aichat tables failed: $e");
      }

      // v18: add aichat_models table if missing
      try {
        final modelsTables = await _db.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='aichat_models'",
        );
        if (modelsTables.isEmpty) {
          logger.i("AppDatabase: Creating aichat_models table...");
          await _db.execute(_aichatModelsDDL);
          await _seedAichatModels(_db);
        } else {
          // Backfill: ensure the default Gemma 4 12B row exists (added after initial v18 seed)
          final gemmaRows = await _db.select(
            "SELECT id FROM aichat_models WHERE name = 'gemma4:12b' OR alias = 'gemma4:12b' LIMIT 1",
          );
          if (gemmaRows.isEmpty) {
            logger.i("AppDatabase: Backfilling default Gemma 4 12B model...");
            final now = DateTime.now().millisecondsSinceEpoch;
            await _db.execute(
              'INSERT OR IGNORE INTO aichat_models (id, alias, "group", name, file, mmproj, type, base_url, enabled, created_at, updated_at) '
              'VALUES (?, ?, ?, ?, NULL, NULL, ?, NULL, 1, ?, ?)',
              [
                const Uuid().v4(),
                'Gemma 4 12B',
                'local',
                'gemma4:12b',
                'gguf',
                now,
                now,
              ],
            );
          }
          // Migrate: alias was incorrectly set to the display name; swap alias ↔ name for all rows
          final oldFormat = await _db.select(
            "SELECT id FROM aichat_models WHERE alias = 'Gemma 4 12B' LIMIT 1",
          );
          if (oldFormat.isNotEmpty) {
            logger.i(
              "AppDatabase: Swapping alias/name to correct semantic order...",
            );
            await _db.execute(
              'UPDATE aichat_models SET alias = name, name = alias',
            );
          }
          // Migrate: update Gemini 2.5 rows to 3.5
          await _db.execute(
            "UPDATE aichat_models SET "
            "  alias = REPLACE(alias, '2.5', '3.5'), "
            "  name  = REPLACE(name,  '2.5', '3.5') "
            "WHERE \"group\" = 'gemini' AND (alias LIKE '%2.5%' OR name LIKE '%2.5%')",
          );
          // Migrate: rename gemini-3.5-pro → gemini-3.1-pro-preview
          await _db.execute(
            "UPDATE aichat_models SET alias = 'gemini-3.1-pro-preview', name = 'Gemini 3.1 Pro' "
            "WHERE alias IN ('gemini-3.5-pro', 'gemini-3.1-pro')",
          );
        }
      } catch (e) {
        logger.e("AppDatabase: Migration of aichat_models table failed: $e");
      }

      // v19: add aichat_skills table if missing
      try {
        final skillsTables = await _db.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='aichat_skills'",
        );
        if (skillsTables.isEmpty) {
          logger.i("AppDatabase: Creating aichat_skills table...");
          await _db.execute(_aichatSkillsDDL);
          await _seedAichatSkills(_db);
        }
      } catch (e) {
        logger.e("AppDatabase: Migration of aichat_skills table failed: $e");
      }

      // v20: add providers.type column; drop aichat_models.api_key column
      try {
        final providerCols = await _db.select("PRAGMA table_info(providers)");
        final hasType = providerCols.any((c) => c['name'] == 'type');
        if (!hasType) {
          logger.i("AppDatabase: Adding type column to providers...");
          await _db.execute(
            "ALTER TABLE providers ADD COLUMN type TEXT NOT NULL DEFAULT 'collection'",
          );
          await _db.execute(
            "UPDATE providers SET type = 'model' "
            "WHERE service IN ('gemini', 'claude', 'openai', 'grok', 'huggingface')",
          );
        }
      } catch (e) {
        logger.e("AppDatabase: Migration v20 (providers.type) failed: $e");
      }

      try {
        final modelCols = await _db.select("PRAGMA table_info(aichat_models)");
        final hasApiKey = modelCols.any((c) => c['name'] == 'api_key');
        if (hasApiKey) {
          logger.i(
            "AppDatabase: Dropping api_key column from aichat_models...",
          );
          await _db.execute("ALTER TABLE aichat_models DROP COLUMN api_key");
        }
      } catch (e) {
        logger.e(
          "AppDatabase: Migration v20 (aichat_models.api_key drop) failed: $e",
        );
      }

      // v21: add hf_repo and chat_handler columns; backfill local models;
      //      insert any new local models that aren't seeded yet
      try {
        final modelCols = await _db.select("PRAGMA table_info(aichat_models)");
        final hasHfRepo = modelCols.any((c) => c['name'] == 'hf_repo');
        if (!hasHfRepo) {
          logger.i(
            "AppDatabase: Adding hf_repo and chat_handler columns to aichat_models...",
          );
          await _db.execute(
            "ALTER TABLE aichat_models ADD COLUMN hf_repo TEXT",
          );
          await _db.execute(
            "ALTER TABLE aichat_models ADD COLUMN chat_handler TEXT",
          );
        }
        // Backfill known local models regardless of whether the columns are new
        final now = DateTime.now().millisecondsSinceEpoch;
        final localBackfills = [
          {
            'alias': 'gemma4:12b',
            'hf_repo': 'ggml-org/gemma-4-12B-it-GGUF',
            'file': 'gemma-4-12B-it-Q4_K_M.gguf',
            'mmproj': 'mmproj-gemma-4-12B-it-Q8_0.gguf',
            'chat_handler': 'Gemma4ChatHandler',
          },
          {
            'alias': 'qwen3:4b',
            'hf_repo': 'bartowski/Qwen_Qwen3.5-4B-GGUF',
            'chat_handler': null,
          },
          {
            'alias': 'llama3.2:3b',
            'hf_repo': 'bartowski/Llama-3.2-3B-Instruct-GGUF',
            'chat_handler': null,
          },
          {
            'alias': 'phi4',
            'hf_repo': 'Swicked86/phi4-mm-gguf',
            'chat_handler': 'Phi3VisionChatHandler',
          },
        ];
        for (final b in localBackfills) {
          // Only set file/mmproj from backfill if the row has no path yet
          final fileClause =
              b.containsKey('file') ? ", file = COALESCE(NULLIF(file, ''), ?)" : '';
          final mmprojClause =
              b.containsKey('mmproj') ? ", mmproj = COALESCE(NULLIF(mmproj, ''), ?)" : '';
          final params = <Object?>[
            b['hf_repo'],
            b['chat_handler'],
            if (b.containsKey('file')) b['file'],
            if (b.containsKey('mmproj')) b['mmproj'],
            now,
            b['alias'],
          ];
          await _db.execute(
            'UPDATE aichat_models SET hf_repo = ?, chat_handler = ?$fileClause$mmprojClause, updated_at = ? '
            'WHERE alias = ?',
            params,
          );
        }
        // Insert downloadable local models that aren't in the DB yet
        final newLocalModels = [
          {
            'alias': 'qwen3:4b',
            'name': 'Qwen 3 4B',
            'file': 'Qwen_Qwen3.5-4B-Q3_K_L.gguf',
            'mmproj': 'mmproj-Qwen_Qwen3.5-4B-f16.gguf',
            'hf_repo': 'bartowski/Qwen_Qwen3.5-4B-GGUF',
            'chat_handler': null,
          },
          {
            'alias': 'llama3.2:3b',
            'name': 'Meta Llama 3.2 3B',
            'file': 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
            'mmproj': null,
            'hf_repo': 'bartowski/Llama-3.2-3B-Instruct-GGUF',
            'chat_handler': null,
          },
          {
            'alias': 'phi4',
            'name': 'Microsoft Phi-4',
            'file': 'phi4-mm-Q4_K_M.gguf',
            'mmproj': 'mmproj-phi4-mm-f16.gguf',
            'hf_repo': 'Swicked86/phi4-mm-gguf',
            'chat_handler': 'Phi3VisionChatHandler',
          },
        ];
        for (final m in newLocalModels) {
          await _db.execute(
            'INSERT OR IGNORE INTO aichat_models '
            '(id, alias, "group", name, file, mmproj, hf_repo, chat_handler, type, enabled, created_at, updated_at) '
            'SELECT ?, ?, \'local\', ?, ?, ?, ?, ?, \'gguf\', 0, ?, ? '
            'WHERE NOT EXISTS (SELECT 1 FROM aichat_models WHERE alias = ?)',
            [
              const Uuid().v4(),
              m['alias'],
              m['name'],
              m['file'],
              m['mmproj'],
              m['hf_repo'],
              m['chat_handler'],
              now,
              now,
              m['alias'],
            ],
          );
        }
      } catch (e) {
        logger.e(
          "AppDatabase: Migration v21 (hf_repo/chat_handler) failed: $e",
        );
      }
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
      // gemma4:12b is bundled with the app; always enabled
      {
        'id': const Uuid().v4(),
        'alias': 'gemma4:12b',
        'group': 'local',
        'name': 'Gemma 4 12B',
        'type': 'gguf',
        'file': 'gemma-4-12B-it-Q4_K_M.gguf',
        'mmproj': 'mmproj-gemma-4-12B-it-Q8_0.gguf',
        'hf_repo': 'ggml-org/gemma-4-12B-it-GGUF',
        'chat_handler': 'Gemma4ChatHandler',
        'enabled': 1,
      },
      // Downloadable local models — disabled until the user downloads them
      {
        'id': const Uuid().v4(),
        'alias': 'qwen3:4b',
        'group': 'local',
        'name': 'Qwen 3 4B',
        'type': 'gguf',
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
        'file': 'phi4-mm-Q4_K_M.gguf',
        'mmproj': 'mmproj-phi4-mm-f16.gguf',
        'hf_repo': 'Swicked86/phi4-mm-gguf',
        'chat_handler': 'Phi3VisionChatHandler',
      },
      // ── Gemini ────────────────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'gemini-2.5-flash',
        'group': 'gemini',
        'name': 'Gemini 2.5 Flash',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'gemini-2.5-pro',
        'group': 'gemini',
        'name': 'Gemini 2.5 Pro',
        'type': 'api',
      },
      // ── Claude ────────────────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'claude-sonnet-4-5',
        'group': 'claude',
        'name': 'Claude Sonnet 4.5',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'claude-opus-4-8',
        'group': 'claude',
        'name': 'Claude Opus 4.8',
        'type': 'api',
      },
      // ── OpenAI ────────────────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'gpt-4o',
        'group': 'openai',
        'name': 'GPT-4o',
        'type': 'api',
      },
      {
        'id': const Uuid().v4(),
        'alias': 'o3',
        'group': 'openai',
        'name': 'OpenAI o3',
        'type': 'api',
      },
      // ── Grok ──────────────────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'grok-3',
        'group': 'grok',
        'name': 'Grok 3',
        'type': 'api',
      },
      // ── Ollama placeholder ────────────────────────────────────────────────
      {
        'id': const Uuid().v4(),
        'alias': 'ollama',
        'group': 'ollama',
        'name': 'Ollama',
        'type': 'ollama',
        'base_url': 'http://localhost:11434',
      },
    ];
    for (final m in models) {
      final enabled = (m['enabled'] as int?) ?? 0;
      await db.execute(
        'INSERT OR IGNORE INTO aichat_models (id, alias, "group", name, file, mmproj, hf_repo, chat_handler, type, base_url, enabled, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          m['id'],
          m['alias'],
          m['group'],
          m['name'],
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
      qwen3_8b_embedding BLOB,
      siglip2_embedding BLOB,
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
