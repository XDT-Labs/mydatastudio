import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/services/email_folder_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';

class EmailFolderUpsertService
    extends RxService<EmailFolderUpsertServiceCommand, EmailFolder> {
  static final EmailFolderUpsertService _singleton = EmailFolderUpsertService();
  static EmailFolderUpsertService get instance => _singleton;

  @override
  Future<EmailFolder> invoke(EmailFolderUpsertServiceCommand command) async {
    isLoading.add(true);
    try {
      final repo = EmailFolderRepository(command.database);
      await retryOnLock(
        () => repo.upsertFolder(command.folder),
        label: 'EmailFolderUpsertService',
      );
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
