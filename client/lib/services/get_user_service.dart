import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:mydatastudio/repositories/user_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';

class GetUserService extends RxService<GetUserServiceCommand, AppUser?> {
  static final GetUserService _singleton = GetUserService();
  static GetUserService get instance => _singleton;

  @override
  Future<AppUser?> invoke(GetUserServiceCommand command) async {
    if (command.password == null) {
      sink.add(null);
      return Future(() => null);
    }
    isLoading.add(true);
    UserRepository repo = UserRepository(DatabaseManager.instance.database);
    AppUser? user = await repo.user(command.password!);
    sink.add(user);
    isLoading.add(false);
    return Future(() => user);
  }
}

class GetUserServiceCommand implements RxCommand {
  String? password;
  GetUserServiceCommand(this.password);
}
