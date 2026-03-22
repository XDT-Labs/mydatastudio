import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:mydatatools/services/rx_service.dart';

class GetEmailsService extends RxService<EmailServiceCommand, List<Email>> {
  static final GetEmailsService _singleton = GetEmailsService();
  static GetEmailsService get instance => _singleton;
  final AppLogger logger = AppLogger(null);

  @override
  Future<List<Email>> invoke(EmailServiceCommand command) async {
    isLoading.add(true);

    // DatabaseManager now opens the connection with NativeDatabase.createInBackground(),
    // so all SQLite I/O is automatically executed on a background thread — no
    // additional work needed here.
    final List<Email> emails = await EmailRepository(
      DatabaseManager.instance.database!,
    ).emails(
      command.collection.id,
      folderId: command.folderId,
      search: command.search,
      sortColumn: command.sortColumn,
      sortAsc: command.sortAsc,
    );

    sink.add(emails);
    isLoading.add(false);
    return emails;
  }
}

class EmailServiceCommand extends RxCommand {
  final Collection collection;
  final String? folderId;
  final String? search;
  final String sortColumn;
  final bool sortAsc;
  EmailServiceCommand(
    this.collection, {
    this.folderId,
    this.search,
    this.sortColumn = 'date',
    this.sortAsc = false,
  });
}
