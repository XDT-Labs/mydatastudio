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

  Future<AichatModel?> getByAlias(String alias) async {
    final rows = await db.select(
      'SELECT * FROM aichat_models WHERE alias = ? LIMIT 1',
      [alias],
    );
    if (rows.isEmpty) return null;
    return AichatModel.fromDbMap(rows.first.cast<String, dynamic>());
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
      'INSERT INTO aichat_models (id, alias, "group", name, file, mmproj, hf_repo, chat_handler, type, base_url, enabled, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'alias = excluded.alias, '
      '"group" = excluded."group", '
      'name = excluded.name, '
      'file = excluded.file, '
      'mmproj = excluded.mmproj, '
      'hf_repo = excluded.hf_repo, '
      'chat_handler = excluded.chat_handler, '
      'type = excluded.type, '
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
        model.hfRepo,
        model.chatHandler,
        model.type,
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
    String? hfRepo,
    String? chatHandler,
    required String type,
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
      hfRepo: hfRepo,
      chatHandler: chatHandler,
      type: type,
      baseUrl: baseUrl,
      enabled: enabled,
      createdAt: now,
      updatedAt: now,
    );
    return upsert(model);
  }

  /// Called after a model is downloaded — updates the file paths and enables the row.
  Future<void> setLocalPath(String id, String filePath, String? mmprojPath) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      'UPDATE aichat_models SET file = ?, mmproj = ?, enabled = 1, updated_at = ? WHERE id = ?',
      [filePath, mmprojPath, now, id],
    );
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      'UPDATE aichat_models SET enabled = ?, updated_at = ? WHERE id = ?',
      [enabled ? 1 : 0, now, id],
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
}
