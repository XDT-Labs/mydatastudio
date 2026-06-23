import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:mydatastudio/repositories/user_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';

class GetUsersService extends RxService<GetUsersServiceCommand, List<AppUser>> {
  static final GetUsersService _singleton = GetUsersService();
  static GetUsersService get instance => _singleton;

  @override
  Future<List<AppUser>> invoke(GetUsersServiceCommand command) async {
    isLoading.add(true);
    UserRepository repo = UserRepository(DatabaseManager.instance.database);
    List<AppUser> users = await repo.users();
    sink.add(users);
    isLoading.add(false);
    return Future(() => users);
  }
}

class GetUsersServiceCommand implements RxCommand {}
