import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/repositories/user_repository.dart';
import 'package:mydatatools/services/rx_service.dart';

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
