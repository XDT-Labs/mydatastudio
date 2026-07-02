import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';

import 'package:mydatastudio/services/rx_service.dart';
import 'package:flutter/material.dart';
import 'package:resqlite/resqlite.dart' show ResqliteQueryException;

class FileUpsertService extends RxService<FileUpsertServiceCommand, File> {
  static final FileUpsertService _singleton = FileUpsertService();
  static FileUpsertService get instance => _singleton;

  /// Maximum number of retry attempts for transient SQLITE_BUSY errors.
  static const int _maxRetries = 3;

  /// Base delay between retries (doubles on each attempt).
  static const Duration _retryBaseDelay = Duration(milliseconds: 200);

  @override
  Future<File> invoke(FileUpsertServiceCommand command) async {
    isLoading.add(true);

    FileDesktopRepository repo = FileDesktopRepository(command.database);

    File? file;
    try {
      file = await _upsertWithRetry(repo, command.file);
      if (file != null) {
        sink.add(file);
      }
      return Future(() => file ?? command.file);
    } catch (err) {
      debugPrint('FileUpsertService error: $err');
    }
    isLoading.add(false);
    return Future(() => command.file);
  }

  /// Attempts the upsert operation with retry logic for SQLITE_BUSY (code 5).
  Future<File?> _upsertWithRetry(
    FileDesktopRepository repo,
    File fileData,
  ) async {
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        File? existing = await repo.getByPath(fileData);
        if (existing == null) {
          return await repo.create(fileData);
        } else {
          return await repo.update(fileData);
        }
      } on ResqliteQueryException catch (e) {
        if (e.sqliteCode == 5 && attempt < _maxRetries) {
          final delay = _retryBaseDelay * (1 << attempt);
          debugPrint(
            'FileUpsertService: SQLITE_BUSY (attempt ${attempt + 1}/$_maxRetries), '
            'retrying in ${delay.inMilliseconds}ms...',
          );
          await Future.delayed(delay);
          continue;
        }
        rethrow;
      }
    }
    return null;
  }
}

class FileUpsertServiceCommand implements RxCommand {
  File file;
  AppDatabase database;
  FileUpsertServiceCommand(this.file, this.database);
}
