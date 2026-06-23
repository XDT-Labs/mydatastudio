import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/services/email_folder_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:resqlite/resqlite.dart' show ResqliteQueryException;

class EmailFolderUpsertService
    extends RxService<EmailFolderUpsertServiceCommand, EmailFolder> {
  static final EmailFolderUpsertService _singleton = EmailFolderUpsertService();
  static EmailFolderUpsertService get instance => _singleton;

  /// Maximum number of retry attempts for transient SQLITE_BUSY errors.
  static const int _maxRetries = 3;

  /// Base delay between retries (doubles on each attempt).
  static const Duration _retryBaseDelay = Duration(milliseconds: 200);

  @override
  Future<EmailFolder> invoke(EmailFolderUpsertServiceCommand command) async {
    isLoading.add(true);
    try {
      await _upsertWithRetry(command);
      sink.add(command.folder);
      return command.folder;
    } finally {
      isLoading.add(false);
    }
  }

  /// Attempts the upsert operation with retry logic for SQLITE_BUSY (code 5).
  Future<void> _upsertWithRetry(EmailFolderUpsertServiceCommand command) async {
    EmailFolderRepository repo = EmailFolderRepository(command.database);
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        await repo.upsertFolder(command.folder);
        return;
      } on ResqliteQueryException catch (e) {
        if (e.sqliteCode == 5 && attempt < _maxRetries) {
          final delay = _retryBaseDelay * (1 << attempt);
          debugPrint(
            'EmailFolderUpsertService: SQLITE_BUSY (attempt ${attempt + 1}/$_maxRetries), '
            'retrying in ${delay.inMilliseconds}ms...',
          );
          await Future.delayed(delay);
          continue;
        }
        rethrow;
      }
    }
  }
}

class EmailFolderUpsertServiceCommand implements RxCommand {
  final EmailFolder folder;
  final AppDatabase database;
  EmailFolderUpsertServiceCommand(this.folder, this.database);
}
