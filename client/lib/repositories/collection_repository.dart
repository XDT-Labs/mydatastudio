import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/collection.dart';

class CollectionRepository {
  AppLogger logger = AppLogger(null);

  Future<List<Collection>> collections() async {
    AppDatabase? db = DatabaseManager.instance.database;

    List<Collection> results = await db?.select(db.collections).get() ?? [];

    return results;
  }

  Future<List<Collection>> collectionsByType(String type) async {
    AppDatabase? db = DatabaseManager.instance.database;

    List<Collection> r =
        await (db?.select(db.collections)
          ?..where((element) => element.type.equals(type)))?.get() ??
        [];
    return r;
  }

  Future<Collection?> collectionById(String val) async {
    AppDatabase? db = DatabaseManager.instance.database;

    List<Collection> r =
        await (db?.select(db.collections)
          ?..where((element) => element.id.equals(val)))?.get() ??
        [];
    return r.first;
  }

  Future<Collection?> getCollectionByPath(String path) async {
    AppDatabase? db = DatabaseManager.instance.database;

    List<Collection> r =
        await (db?.select(db.collections)
          ?..where((element) => element.path.equals(path)))?.get() ??
        [];
    return r.first;
  }

  ///
  /// Create new collection
  Future<Collection?> addCollection(Collection val) async {
    AppDatabase? db = DatabaseManager.instance.database;

    db?.into(db.collections).insert(val);
    return Future(() => val);
  }

  ///
  /// Update an existing collection (used for re-auth token refresh)
  Future<Collection?> updateCollection(Collection val) async {
    AppDatabase? db = DatabaseManager.instance.database;

    await db?.update(db.collections).replace(val);
    return Future(() => val);
  }

  ///
  /// Update the scan date for services that check external systems on a schedule, such as email
  void updateLastScanDate(Collection collection, DateTime? value) async {
    AppDatabase? db = DatabaseManager.instance.database;
    //update date
    collection.lastScanDate = DateTime.now();
    await db?.update(db.collections).write(collection);
  }

  Future<void> deleteCollection(String id) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db != null) {
      await (db.delete(db.collections)..where((t) => t.id.equals(id))).go();
    }
  }
}
