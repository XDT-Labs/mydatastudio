import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:drift/drift.dart' as drift;

class FileDesktopRepository {
  AppLogger logger = AppLogger(null);
  AppDatabase db;

  FileDesktopRepository(this.db);

  Future<File?> getByPath(File f) async {
    File? file =
        await (db.select(db.files)
          ..where((t) => t.id.equals(f.id))).getSingleOrNull();

    return Future(() => file);
  }

  Future<List<File>> getByParentPath(
    String collectionId,
    String path, {
    int limit = 200,
    int offset = 0,
  }) async {
    final query =
        db.select(db.files)
          ..where(
            (t) =>
                t.collectionId.equals(collectionId) &
                t.parent.equals(path) &
                t.isDeleted.equals(false),
          )
          ..orderBy([(t) => drift.OrderingTerm(expression: t.name)])
          ..limit(limit, offset: offset);

    return query.get();
  }

  Future<File?> create(File f) async {
    await db.into(db.files).insert(f);
    //grab latest
    File? file =
        await (db.select(db.files)
          ..where((t) => t.id.equals(f.id))).getSingleOrNull();

    return Future(() => file);
  }

  Future<File?> update(File f) async {
    await db.update(db.files).replace(f);
    //grab latest
    File? file =
        await (db.select(db.files)
          ..where((t) => t.id.equals(f.id))).getSingleOrNull();

    return file;
  }

  Future<File?> delete(File f) async {
    await db.delete(db.files).delete(f);
    return Future(() => null);
  }

  Future<void> markMissingAsDeleted(String collectionId, String scannedPath, DateTime scanStartTime, {bool recursive = true, bool isCloud = false, bool isFullScan = false}) async {
    String searchPath = scannedPath;
    if (!searchPath.endsWith('/')) {
      searchPath += '/';
    }
    
    await (db.update(db.files)
          ..where((t) =>
              t.collectionId.equals(collectionId) &
              (isCloud 
                  ? (recursive && isFullScan ? const drift.Constant(true) : t.parent.equals(scannedPath))
                  : (recursive ? (t.parent.equals(scannedPath) | t.parent.like('$searchPath%')) : t.parent.equals(scannedPath))) &
              (t.lastScannedDate.isNull() | t.lastScannedDate.isSmallerThanValue(scanStartTime))))
        .write(const FilesCompanion(isDeleted: drift.Value(true)));
  }

  Future<void> upsertAll(List<File> fileList) async {
    if (fileList.isEmpty) return;

    List<String> allIds = fileList.map((f) => f.id).toList();

    // Find which IDs already exist in the database
    List<String> existingIds = await (db.select(db.files)
          ..where((t) => t.id.isIn(allIds)))
        .map((row) => row.id)
        .get();

    // Separate into new files (to insert) and existing files (to update)
    List<File> newFiles = fileList.where((f) => !existingIds.contains(f.id)).toList();
    
    // 1. Batch insert the new files
    if (newFiles.isNotEmpty) {
      await db.batch((batch) {
        batch.insertAll(db.files, newFiles);
      });
    }

    // 2. Perform a lightweight targeted update just for the lastScannedDate and isDeleted on existing files
    if (existingIds.isNotEmpty) {
      await db.batch((batch) {
        for (final file in fileList) {
          if (existingIds.contains(file.id)) {
            batch.update(
              db.files,
              FilesCompanion(
                name: drift.Value(file.name),
                path: drift.Value(file.path),
                parent: drift.Value(file.parent),
                dateLastModified: drift.Value(file.dateLastModified),
                lastScannedDate: drift.Value(file.lastScannedDate),
                size: drift.Value(file.size),
                contentType: drift.Value(file.contentType),
                thumbnail: drift.Value(file.thumbnail),
                downloadUrl: drift.Value(file.downloadUrl),
                emailId: drift.Value(file.emailId),
                isDeleted: const drift.Value(false),
              ),
              where: (t) => t.id.equals(file.id),
            );
          }
        }
      });
    }
  }

  Future<List<File>> getByEmailId(String emailId) async {
    return await (db.select(db.files)
          ..where((t) => t.emailId.equals(emailId) & t.isDeleted.equals(false)))
        .get();
  }

  Future<List<File>> getByEmailIds(List<String> emailIds) async {
    return await (db.select(db.files)
          ..where((t) => t.emailId.isIn(emailIds) & t.isDeleted.equals(false)))
        .get();
  }

  Future<List<File>> getFilesToDownload(String collectionId) async {
    return await (db.select(db.files)
          ..where(
            (t) =>
                t.collectionId.equals(collectionId) &
                t.localPath.isNull() &
                t.isDeleted.equals(false),
          ))
        .get();
  }

  Future<void> deleteAllByCollectionId(String collectionId) async {
    await (db.delete(db.files)..where((t) => t.collectionId.equals(collectionId))).go();
  }
}
