import 'package:mydatatools/modules/email/services/email_folder_repository.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/services/rx_service.dart';

class EmailFolderServiceCommand {
  final String collectionId;
  EmailFolderServiceCommand(this.collectionId);
}

class GetEmailFoldersService extends RxService<EmailFolderServiceCommand, List<EmailFolder>> {
  static final GetEmailFoldersService instance = GetEmailFoldersService._internal();

  factory GetEmailFoldersService() {
    return instance;
  }

  GetEmailFoldersService._internal() : super();

  @override
  Future<List<EmailFolder>> invoke(EmailFolderServiceCommand command) async {
    isLoading.add(true);
    EmailFolderRepository repo = EmailFolderRepository(DatabaseManager.instance.database!);
    
    // Watch folders for this collection
    final database = DatabaseManager.instance.database!;
    final query = database.select(database.emailFolders)
      ..where((t) => t.collectionId.equals(command.collectionId));
    
    final folders = await repo.byCollectionId(command.collectionId);
    sink.add(folders);
    isLoading.add(false);

    // If we want it reactive, we should subscribe to the drift watch
    // Note: In RxService, multiple calls to invoke might result in multiple subscriptions if not handled.
    // For now, we'll just return the initial list and rely on the sink to push updates.
    query.watch().listen((event) {
      sink.add(event);
    });

    return folders;
  }
}
