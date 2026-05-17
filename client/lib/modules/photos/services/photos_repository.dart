import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/files/files_constants.dart';

import 'package:intl/intl.dart';

class PhotosRepository {
  AppLogger logger = AppLogger(null);

  Future<List<File>> photos() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    final rows = await db.select(
      "SELECT * FROM files WHERE content_type = ? ORDER BY date_created DESC",
      [FilesConstants.mimeTypeImage],
    );
    return rows.map((r) => File.fromDbMap(r)).toList();
  }

  Future<Map<String, List<File>>> photosByDate() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return {};
    DateFormat dateFormat = DateFormat("yyyy-MM-dd");
    Map<String, List<File>> groupedImages = {};

    final rows = await db.select(
      "SELECT * FROM files WHERE content_type = ? ORDER BY date_created ASC",
      [FilesConstants.mimeTypeImage],
    );
    List<File> p = rows.map((r) => File.fromDbMap(r)).toList();

    for (var f in p) {
      String group = dateFormat.format(f.dateCreated);

      if (groupedImages[group] == null) {
        groupedImages[group] = [];
      }
      List<File>? groupList = groupedImages[group];
      groupList?.add(f);
    }

    return groupedImages;
  }
}
