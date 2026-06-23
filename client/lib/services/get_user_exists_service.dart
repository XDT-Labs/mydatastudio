import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:mydatastudio/repositories/user_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';

class GetUserExistsService
    extends RxService<GetUserExistsServiceCommand, AppUser?> {
  @override
  Future<AppUser?> invoke(GetUserExistsServiceCommand command) async {
    isLoading.add(true);
    UserRepository repo = UserRepository(DatabaseManager.instance.database);
    AppUser? user = await repo.userExists();
    sink.add(user);
    isLoading.add(false);

    return Future(() => user);
  }
}

class GetUserExistsServiceCommand implements RxCommand {}
