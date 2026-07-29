import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/app_logger.dart';

/// Module logger. AppLogger writes to the session log file as well as the
/// console; a bare print() only reaches the console.
final AppLogger _logger = AppLogger(null);

class GetCollectionsService
    extends RxService<GetCollectionsServiceCommand, List<Collection>> {
  static GetCollectionsService _instance = GetCollectionsService();
  static GetCollectionsService get instance => _instance;
  static set instance(GetCollectionsService val) => _instance = val;

  GetCollectionsServiceCommand? currentCommand;

  @override
  Future<List<Collection>> invoke(GetCollectionsServiceCommand command) async {
    currentCommand = command;
    if (DatabaseManager.instance.database == null) {
      _logger.d(
        'GetCollectionsService.invoke: database is null, skipping DB query',
      );
      return sink.valueOrNull ?? [];
    }
    CollectionRepository repo = CollectionRepository();

    // Always push all collections to the sink.
    // Observers can then filter by type (file, email) as needed.
    // Note: We deliberately do NOT emit isLoading here. This is a fast
    // DB query and the shared isLoading stream would cause unrelated
    // UI sections to show loading spinners (e.g., FileDrawer showing
    // a spinner when only Gmail login triggered a refresh).
    final allCollections = await repo.collections();
    _logger.d(
      'GetCollectionsService.invoke: found ${allCollections.length} collections',
    );
    sink.add(allCollections);

    return Future(() => allCollections);
  }

  void addCollection(Collection c) async {
    await CollectionRepository().addCollection(c);
    //refresh list with current command type (if defined)
    invoke(GetCollectionsServiceCommand(currentCommand?.type));
  }
}

class GetCollectionsServiceCommand implements RxCommand {
  String? type;
  GetCollectionsServiceCommand(this.type);
}
