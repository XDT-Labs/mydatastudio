import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:drift/drift.dart' as drift;

class FolderDesktopRepository {
  AppLogger logger = AppLogger(null);
  AppDatabase db;

  FolderDesktopRepository(this.db);

  Future<Folder?> getByPath(Folder f) async {
    Folder? folder =
      await (db.select(db.folders)
          ..where((t) => t.path.equals(f.path) & t.collectionId.equals(f.collectionId))).getSingleOrNull();

    return Future(() => folder);
  }

  Future<List<Folder>> getByParentPath(
    String collectionId,
    String path, {
    int limit = 500,
    int offset = 0,
  }) async {
    final query =
        db.select(db.folders)
          ..where(
            (t) =>
                t.collectionId.equals(collectionId) & t.parent.equals(path),
          )
          ..orderBy([(t) => drift.OrderingTerm(expression: t.name)])
          ..limit(limit, offset: offset);

    return query.get();
  }

  Future<Folder?> create(Folder f) async {
    await db.into(db.folders).insert(f);
    //grab latest
    Folder? folder =
        await (db.select(db.folders)
          ..where((t) => t.id.equals(f.id))).getSingleOrNull();

    return Future(() => folder);
  }

  Future<Folder?> update(Folder f) async {
    await db.update(db.folders).replace(f);
    //grab latest
    Folder? folder =
        await (db.select(db.folders)
          ..where((t) => t.id.equals(f.id))).getSingleOrNull();

    return Future(() => folder);
  }

  Future<Folder?> delete(Folder f) async {
    await db.delete(db.folders).delete(f);
    return Future(() => null);
  }

  Future<void> deleteMissing(String collectionId, String scannedPath, DateTime scanStartTime, {bool recursive = true, bool isCloud = false, bool isFullScan = false}) async {
    String searchPath = scannedPath;
    if (!searchPath.endsWith('/')) {
      searchPath += '/';
    }

    await (db.delete(db.folders)
          ..where((t) =>
              t.collectionId.equals(collectionId) &
              (isCloud 
                  ? (recursive && isFullScan ? const drift.Constant(true) : t.parent.equals(scannedPath))
                  : (recursive ? (t.parent.equals(scannedPath) | t.parent.like('$searchPath%')) : t.parent.equals(scannedPath))) &
              (t.lastScannedDate.isNull() | t.lastScannedDate.isSmallerThanValue(scanStartTime))))
        .go();
  }

  Future<void> deleteAllByCollectionId(String collectionId) async {
    await (db.delete(db.folders)..where((t) => t.collectionId.equals(collectionId))).go();
  }
}
