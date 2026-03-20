import 'dart:io' as io;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:path/path.dart' as p;

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
      // 1. Fetch collection info before deleting it
      final collection = await (db.select(db.collections)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (collection == null) return;

      await db.transaction(() async {
        // 2. Delete all file embeddings associated with files in this collection
        final fileIdsInCollection = db.selectOnly(db.files)
          ..addColumns([db.files.id])
          ..where(db.files.collectionId.equals(id));
        final fileIdList = await fileIdsInCollection.map((row) => row.read(db.files.id)!).get();
        
        if (fileIdList.isNotEmpty) {
           await (db.delete(db.filesEmbeddings)..where((t) => t.fileId.isIn(fileIdList))).go();
        }

        // 3. Delete all files linked to this collection
        await (db.delete(db.files)..where((t) => t.collectionId.equals(id))).go();

        // 4. Delete all folders linked to this collection
        await (db.delete(db.folders)..where((t) => t.collectionId.equals(id))).go();

        // 5. Delete all emails linked to this collection
        await (db.delete(db.emails)..where((t) => t.collectionId.equals(id))).go();

        // 6. Delete all email folders linked to this collection
        await (db.delete(db.emailFolders)..where((t) => t.collectionId.equals(id))).go();

        // 7. Finally delete the collection itself
        await (db.delete(db.collections)..where((t) => t.id.equals(id))).go();
      });

      // 8. Physical disk cleanup (especially for email attachments/cache)
      if (collection.type == 'email') {
        try {
          String? appDir = MainApp.appDataDirectory.value;
          if (appDir != null) {
            final collectionDiskPath = p.join(appDir, 'files', 'email', collection.id);
            final dir = io.Directory(collectionDiskPath);
            if (await dir.exists()) {
              await dir.delete(recursive: true);
              logger.i("Deleted collection disk path: $collectionDiskPath");
            }
          }
        } catch (e) {
          logger.e("Failed to delete collection files from disk: $e");
        }
      }
    }
  }
}
