import 'package:mydatatools/models/tables/collection.dart';
import 'package:rxdart/rxdart.dart';

class CollectionScanner {
  final BehaviorSubject<bool> isScanning = BehaviorSubject<bool>.seeded(false);

  Future<int> start(
    Collection collection,
    String? path,
    bool recursive,
    bool force,
  ) async {
    return Future(() => -1);
  }

  Future<void> moveToTrash(
    Collection collection,
    String folderId,
    List<int> uids,
  ) async {}

  void stop() async {}
}
