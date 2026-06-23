import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';

class EmailUpsertService
    extends RxService<EmailUpsertServiceCommand, List<Email>> {
  static final EmailUpsertService _singleton = EmailUpsertService();
  static EmailUpsertService get instance => _singleton;

  @override
  Future<List<Email>> invoke(EmailUpsertServiceCommand command) async {
    isLoading.add(true);
    EmailRepository repo = EmailRepository(command.database);
    try {
      await repo.addEmails(command.emails);
      sink.add(command.emails);
      return command.emails;
    } finally {
      isLoading.add(false);
    }
  }
}

class EmailUpsertServiceCommand implements RxCommand {
  final List<Email> emails;
  final AppDatabase database;
  EmailUpsertServiceCommand(this.emails, this.database);
}
