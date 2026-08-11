import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/search/services/email_contact_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';

class EmailUpsertService
    extends RxService<EmailUpsertServiceCommand, List<Email>> {
  static final EmailUpsertService _singleton = EmailUpsertService();
  static EmailUpsertService get instance => _singleton;

  @override
  Future<List<Email>> invoke(EmailUpsertServiceCommand command) async {
    isLoading.add(true);
    try {
      await _upsertWithRetry(command);
      await _indexContacts(command);
      sink.add(command.emails);
      return command.emails;
    } finally {
      isLoading.add(false);
    }
  }

  /// Folds this batch's addresses into the `contacts` index.
  ///
  /// Hooked here because every scanner — Gmail, Yahoo, Outlook, PST — reaches
  /// the database through this one service, so one call covers all of them and
  /// none can add mail the index never sees.
  ///
  /// Deliberately after the upsert and deliberately non-fatal: contacts are a
  /// derived convenience (autocomplete and name resolution), and losing an
  /// increment costs a slightly mis-ranked suggestion. Letting that failure
  /// propagate would instead make the caller count successfully-stored mail as
  /// failed — and for a PST import, which runs exactly once and is never
  /// re-synced, those messages would be lost for good.
  Future<void> _indexContacts(EmailUpsertServiceCommand command) async {
    try {
      await EmailContactRepository(
        command.database,
      ).indexEmails(command.emails);
    } catch (e, stackTrace) {
      AppLogger(null).w(
        'EmailUpsertService: contact indexing failed for '
        '${command.emails.length} emails: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Upserts the batch, retrying transient lock contention.
  ///
  /// This was the only upsert path with no retry at all, while the file, folder
  /// and email-folder services all had one. A momentary write lock — the
  /// embedding isolate, a mailbox sync and a PST import all writing at once —
  /// threw straight out and the caller counted the message as failed. For PST
  /// that loss is permanent: the archive imports exactly once and is never
  /// re-synced, so two of 1181 emails were dropped on each of two runs.
  ///
  /// `addEmails` writes inside `database.transaction(...)`, so the failure
  /// arrives as `ResqliteTransactionException`, not the query exception the
  /// sibling services catch — see [isRetryableLockError] for why that
  /// distinction silently defeated the first version of this fix.
  Future<void> _upsertWithRetry(EmailUpsertServiceCommand command) {
    final repo = EmailRepository(command.database);
    return retryOnLock(
      () => repo.addEmails(command.emails),
      label: 'EmailUpsertService',
    );
  }
}

class EmailUpsertServiceCommand implements RxCommand {
  final List<Email> emails;
  final AppDatabase database;
  EmailUpsertServiceCommand(this.emails, this.database);
}
