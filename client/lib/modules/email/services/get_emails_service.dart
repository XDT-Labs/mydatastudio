import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';

class GetEmailsService extends RxService<EmailServiceCommand, List<Email>> {
  static final GetEmailsService _singleton = GetEmailsService();
  static GetEmailsService get instance => _singleton;
  final AppLogger logger = AppLogger(null);

  @override
  Future<List<Email>> invoke(EmailServiceCommand command) async {
    isLoading.add(true);

    final List<Email> emails = await EmailRepository(
      DatabaseManager.instance.database!,
    ).emails(
      command.collection.id,
      folderId: command.folderId,
      search: command.search,
      sortColumn: command.sortColumn,
      sortAsc: command.sortAsc,
      limit: command.limit,
      offset: command.offset,
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

  /// Number of rows to fetch. Defaults to 100. Pass -1 to fetch all rows.
  final int limit;
  final int offset;

  EmailServiceCommand(
    this.collection, {
    this.folderId,
    this.search,
    this.sortColumn = 'date',
    this.sortAsc = false,
    this.limit = 100,
    this.offset = 0,
  });
}
