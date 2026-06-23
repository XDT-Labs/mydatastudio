import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/app.dart';
import 'package:mydatastudio/database_manager.dart';

class AppRepository {
  AppLogger logger = AppLogger(null);

  /// Get a list of all Apps
  Future<List<App>> apps() async {
    AppDatabase? database = DatabaseManager.instance.database;
    if (database == null) return [];
    final rows = await database.select(
      'SELECT * FROM apps ORDER BY "order" ASC',
    );
    return rows.map((r) => App.fromDbMap(r)).toList();
  }
}
