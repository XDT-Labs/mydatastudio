import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/modules/files/services/repositories/folder_repository.dart';

import 'package:mydatatools/services/rx_service.dart';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

class FolderUpsertService
    extends RxService<FolderUpsertServiceCommand, Folder?> {
  static final FolderUpsertService _singleton = FolderUpsertService();
  static FolderUpsertService get instance => _singleton;

  /// Maximum number of retry attempts for transient SQLITE_BUSY errors.
  static const int _maxRetries = 3;

  /// Base delay between retries (doubles on each attempt).
  static const Duration _retryBaseDelay = Duration(milliseconds: 200);

  @override
  Future<Folder?> invoke(FolderUpsertServiceCommand command) async {
    // AppDatabase database = await DatabaseRepository.instance.database;

    isLoading.add(true);

    FolderDesktopRepository repo = FolderDesktopRepository(command.database);

    Folder? folder;
    try {
      folder = await _upsertWithRetry(repo, command.folder);
      if (folder != null) {
        sink.add(folder);
      }
    } catch (err) {
      debugPrint('FolderUpsertService error: $err');
    }
    //UserRepository repo = UserRepository()
    //AppUser? user = await repo.user(command.password!)
    isLoading.add(false);
    return Future(() => folder);
  }

  /// Attempts the upsert operation with retry logic for SQLITE_BUSY (code 5).
  ///
  /// SQLite returns code 5 when the database write lock is held by another
  /// connection longer than the configured busy_timeout. This happens when
  /// multiple connections compete for the write lock. Retrying with backoff
  /// resolves transient contention.
  Future<Folder?> _upsertWithRetry(
    FolderDesktopRepository repo,
    Folder folderData,
  ) async {
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        Folder? existing = await repo.getByPath(folderData);
        if (existing == null) {
          return await repo.create(folderData);
        } else {
          folderData.id = existing.id; // Preserve existing database ID
          return await repo.update(folderData);
        }
      } on SqliteException catch (e) {
        if (e.resultCode == 5 && attempt < _maxRetries) {
          // SQLITE_BUSY — wait with exponential backoff then retry
          final delay = _retryBaseDelay * (1 << attempt);
          debugPrint(
            'FolderUpsertService: SQLITE_BUSY (attempt ${attempt + 1}/$_maxRetries), '
            'retrying in ${delay.inMilliseconds}ms...',
          );
          await Future.delayed(delay);
          continue;
        }
        rethrow; // Not SQLITE_BUSY or exhausted retries
      }
    }
    return null; // Should not reach here
  }
}

class FolderUpsertServiceCommand implements RxCommand {
  Folder folder;
  AppDatabase database;
  FolderUpsertServiceCommand(this.folder, this.database);
}
