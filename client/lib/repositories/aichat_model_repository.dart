import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/aichat_model.dart';
import 'package:uuid/uuid.dart';

class AichatModelRepository {
  final AppDatabase db;
  static const _uuid = Uuid();

  AichatModelRepository(this.db);

  Future<List<AichatModel>> getAll() async {
    final rows = await db.select(
      'SELECT * FROM aichat_models ORDER BY "group", alias',
    );
    return rows.map((r) => AichatModel.fromDbMap(r.cast<String, dynamic>())).toList();
  }

  Future<List<AichatModel>> getEnabled() async {
    final rows = await db.select(
      'SELECT * FROM aichat_models WHERE enabled = 1 ORDER BY "group", alias',
    );
    return rows.map((r) => AichatModel.fromDbMap(r.cast<String, dynamic>())).toList();
  }

  Future<List<AichatModel>> getByGroup(String group) async {
    final rows = await db.select(
      'SELECT * FROM aichat_models WHERE "group" = ? ORDER BY alias',
      [group],
    );
    return rows.map((r) => AichatModel.fromDbMap(r.cast<String, dynamic>())).toList();
  }

  Future<AichatModel?> getById(String id) async {
    final rows = await db.select(
      'SELECT * FROM aichat_models WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return AichatModel.fromDbMap(rows.first.cast<String, dynamic>());
  }

  Future<AichatModel> upsert(AichatModel model) async {
    await db.execute(
      'INSERT INTO aichat_models (id, alias, "group", name, file, mmproj, type, api_key, base_url, enabled, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'alias = excluded.alias, '
      '"group" = excluded."group", '
      'name = excluded.name, '
      'file = excluded.file, '
      'mmproj = excluded.mmproj, '
      'type = excluded.type, '
      'api_key = excluded.api_key, '
      'base_url = excluded.base_url, '
      'enabled = excluded.enabled, '
      'updated_at = excluded.updated_at',
      [
        model.id,
        model.alias,
        model.group,
        model.name,
        model.file,
        model.mmproj,
        model.type,
        model.apiKey,
        model.baseUrl,
        model.enabled ? 1 : 0,
        model.createdAt.millisecondsSinceEpoch,
        model.updatedAt.millisecondsSinceEpoch,
      ],
    );
    return model;
  }

  Future<AichatModel> create({
    required String alias,
    required String group,
    required String name,
    String? file,
    String? mmproj,
    required String type,
    String? apiKey,
    String? baseUrl,
    bool enabled = false,
  }) async {
    final now = DateTime.now();
    final model = AichatModel(
      id: _uuid.v4(),
      alias: alias,
      group: group,
      name: name,
      file: file,
      mmproj: mmproj,
      type: type,
      apiKey: apiKey,
      baseUrl: baseUrl,
      enabled: enabled,
      createdAt: now,
      updatedAt: now,
    );
    return upsert(model);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      'UPDATE aichat_models SET enabled = ?, updated_at = ? WHERE id = ?',
      [enabled ? 1 : 0, now, id],
    );
  }

  Future<void> setApiKeyForGroup(String group, String apiKey) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      'UPDATE aichat_models SET api_key = ?, updated_at = ? WHERE "group" = ?',
      [apiKey, now, group],
    );
  }

  Future<void> setBaseUrl(String id, String baseUrl) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      'UPDATE aichat_models SET base_url = ?, updated_at = ? WHERE id = ?',
      [baseUrl, now, id],
    );
  }

  Future<void> delete(String id) async {
    await db.execute('DELETE FROM aichat_models WHERE id = ?', [id]);
  }

  Stream<List<AichatModel>> watchAll() {
    return db
        .stream('SELECT * FROM aichat_models ORDER BY "group", alias')
        .map((rows) => rows.map((r) => AichatModel.fromDbMap(r.cast<String, dynamic>())).toList());
  }

  /// Returns the api_key for the first model matching the group (all share one key per group).
  Future<String?> getApiKeyForGroup(String group) async {
    final rows = await db.select(
      'SELECT api_key FROM aichat_models WHERE "group" = ? LIMIT 1',
      [group],
    );
    if (rows.isEmpty) return null;
    return rows.first['api_key'] as String?;
  }
}
