import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';
import 'package:resqlite/resqlite.dart' show ResqliteException;

class EmailUpsertService
    extends RxService<EmailUpsertServiceCommand, List<Email>> {
  static final EmailUpsertService _singleton = EmailUpsertService();
  static EmailUpsertService get instance => _singleton;

  /// Maximum number of retry attempts for transient SQLITE_BUSY errors.
  static const int _maxRetries = 3;

  /// Base delay between retries (doubles on each attempt).
  static const Duration _retryBaseDelay = Duration(milliseconds: 200);

  @override
  Future<List<Email>> invoke(EmailUpsertServiceCommand command) async {
    isLoading.add(true);
    try {
      await _upsertWithRetry(command);
      sink.add(command.emails);
      return command.emails;
    } finally {
      isLoading.add(false);
    }
  }

  /// Attempts the upsert with retry logic for transient lock contention.
  ///
  /// This was the only upsert path with no retry at all, while the file, folder
  /// and email-folder services all had one. A momentary write lock — the
  /// embedding isolate, a mailbox sync and a PST import all writing at once —
  /// threw straight out, and the caller counted the message as failed.
  ///
  /// For PST that loss is permanent: the archive is imported exactly once and
  /// never re-synced, so emails that lose this race simply never existed in the
  /// app. Two out of 1181 were dropped on each of two consecutive imports.
  ///
  /// `addEmails` runs its inserts inside `database.transaction(...)`, so the
  /// failure arrives as `ResqliteTransactionException: database is locked`
  /// (operation 'begin'), *not* as a query exception. A first attempt at this
  /// retry caught only the latter and changed nothing — hence the explicit
  /// handling of both above. The retry re-runs the whole transaction, which is
  /// safe because the statement is an idempotent upsert.
  Future<void> _upsertWithRetry(EmailUpsertServiceCommand command) async {
    EmailRepository repo = EmailRepository(command.database);
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        await repo.addEmails(command.emails);
        return;
      } on ResqliteException catch (e) {
        if (isRetryableLockError(e) && attempt < _maxRetries) {
          final delay = _retryBaseDelay * (1 << attempt);
          debugPrint(
            'EmailUpsertService: sqlite code ${sqliteCodeOf(e)} '
            '(attempt ${attempt + 1}/$_maxRetries), '
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

class EmailUpsertServiceCommand implements RxCommand {
  final List<Email> emails;
  final AppDatabase database;
  EmailUpsertServiceCommand(this.emails, this.database);
}
