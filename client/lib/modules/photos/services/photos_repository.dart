import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/helpers/file_path_resolver.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/files/files_constants.dart';

import 'package:intl/intl.dart';

class PhotosRepository {
  AppLogger logger = AppLogger(null);

  Future<List<File>> photos() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    final rows = await db.select(
      "SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner"
      " FROM files f"
      " JOIN collections c ON f.collection_id = c.id"
      " WHERE f.content_type = ? ORDER BY f.date_created DESC",
      [FilesConstants.mimeTypeImage],
    );
    return rows.map((r) => _fileWithAbsolutePath(r)).toList();
  }

  Future<Map<String, List<File>>> photosByDate() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return {};
    DateFormat dateFormat = DateFormat("yyyy-MM-dd");
    Map<String, List<File>> groupedImages = {};

    final rows = await db.select(
      "SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner"
      " FROM files f"
      " JOIN collections c ON f.collection_id = c.id"
      " WHERE f.content_type = ? ORDER BY f.date_created ASC",
      [FilesConstants.mimeTypeImage],
    );

    for (var r in rows) {
      final f = _fileWithAbsolutePath(r);
      final group = dateFormat.format(f.dateCreated);
      groupedImages.putIfAbsent(group, () => []).add(f);
    }

    return groupedImages;
  }

  File _fileWithAbsolutePath(Map<String, dynamic> row) {
    final file = File.fromDbMap(row);
    final fakeCollection = Collection(
      id: file.collectionId,
      name: '',
      path: (row['col_path'] as String?) ?? '',
      type: '',
      scanner: (row['scanner'] as String?) ?? '',
      scanStatus: '',
      needsReAuth: false,
      localCopyPath: row['local_copy_path'] as String?,
    );
    file.path = FilePathResolver.absolute(file, fakeCollection);
    return file;
  }
}
