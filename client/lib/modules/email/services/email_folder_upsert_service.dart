import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/modules/email/services/email_folder_repository.dart';
import 'package:mydatatools/services/rx_service.dart';

class EmailFolderUpsertService extends RxService<EmailFolderUpsertServiceCommand, EmailFolder> {
  static final EmailFolderUpsertService _singleton = EmailFolderUpsertService();
  static EmailFolderUpsertService get instance => _singleton;

  @override
  Future<EmailFolder> invoke(EmailFolderUpsertServiceCommand command) async {
    isLoading.add(true);
    EmailFolderRepository repo = EmailFolderRepository(command.database);
    try {
      await repo.upsertFolder(command.folder);
      sink.add(command.folder);
      return command.folder;
    } finally {
      isLoading.add(false);
    }
  }
}

class EmailFolderUpsertServiceCommand implements RxCommand {
  final EmailFolder folder;
  final AppDatabase database;
  EmailFolderUpsertServiceCommand(this.folder, this.database);
}
