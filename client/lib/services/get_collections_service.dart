import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/services/rx_service.dart';

class GetCollectionsService
    extends RxService<GetCollectionsServiceCommand, List<Collection>> {
  static final GetCollectionsService _singleton = GetCollectionsService();
  static GetCollectionsService get instance => _singleton;

  GetCollectionsServiceCommand? currentCommand;

  @override
  Future<List<Collection>> invoke(GetCollectionsServiceCommand command) async {
    isLoading.add(true);
    currentCommand = command;
    CollectionRepository repo = CollectionRepository();
    
    // Always push all collections to the sink. 
    // Observers can then filter by type (file, email) as needed.
    final allCollections = await repo.collections();
    sink.add(allCollections);
    
    isLoading.add(false);
    return Future(() => allCollections);
  }

  void addCollection(Collection c) {
    CollectionRepository repo = CollectionRepository();
    //save
    repo.addCollection(c);
    //refresh list with current command type (if defined)
    invoke(GetCollectionsServiceCommand(currentCommand?.type));
  }
}

class GetCollectionsServiceCommand implements RxCommand {
  String? type;
  GetCollectionsServiceCommand(this.type);
}
