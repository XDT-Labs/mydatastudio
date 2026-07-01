import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/aichat_skill.dart';
import 'package:uuid/uuid.dart';

class AichatSkillsRepository {
  final AppDatabase db;
  static const _uuid = Uuid();

  AichatSkillsRepository(this.db);

  Future<List<AichatSkill>> getAll() async {
    final rows = await db.select(
      'SELECT * FROM aichat_skills ORDER BY trigger',
    );
    return rows.map((r) => AichatSkill.fromDbMap(r.cast<String, dynamic>())).toList();
  }

  Future<List<AichatSkill>> getEnabled() async {
    final rows = await db.select(
      'SELECT * FROM aichat_skills WHERE enabled = 1 ORDER BY trigger',
    );
    return rows.map((r) => AichatSkill.fromDbMap(r.cast<String, dynamic>())).toList();
  }

  Future<AichatSkill?> getByTrigger(String trigger) async {
    final rows = await db.select(
      'SELECT * FROM aichat_skills WHERE trigger = ? AND enabled = 1 LIMIT 1',
      [trigger],
    );
    if (rows.isEmpty) return null;
    return AichatSkill.fromDbMap(rows.first.cast<String, dynamic>());
  }

  Future<AichatSkill?> getById(String id) async {
    final rows = await db.select(
      'SELECT * FROM aichat_skills WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return AichatSkill.fromDbMap(rows.first.cast<String, dynamic>());
  }

  Future<AichatSkill> upsert(AichatSkill skill) async {
    await db.execute(
      'INSERT INTO aichat_skills (id, trigger, name, description, system_prompt, enabled, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET '
      'trigger = excluded.trigger, '
      'name = excluded.name, '
      'description = excluded.description, '
      'system_prompt = excluded.system_prompt, '
      'enabled = excluded.enabled, '
      'updated_at = excluded.updated_at',
      [
        skill.id,
        skill.trigger,
        skill.name,
        skill.description,
        skill.systemPrompt,
        skill.enabled ? 1 : 0,
        skill.createdAt.millisecondsSinceEpoch,
        skill.updatedAt.millisecondsSinceEpoch,
      ],
    );
    return skill;
  }

  Future<AichatSkill> create({
    required String trigger,
    required String name,
    String? description,
    required String systemPrompt,
    bool enabled = true,
  }) async {
    final now = DateTime.now();
    final skill = AichatSkill(
      id: _uuid.v4(),
      trigger: trigger,
      name: name,
      description: description,
      systemPrompt: systemPrompt,
      enabled: enabled,
      createdAt: now,
      updatedAt: now,
    );
    return upsert(skill);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      'UPDATE aichat_skills SET enabled = ?, updated_at = ? WHERE id = ?',
      [enabled ? 1 : 0, now, id],
    );
  }

  Future<void> delete(String id) async {
    await db.execute('DELETE FROM aichat_skills WHERE id = ?', [id]);
  }

  Stream<List<AichatSkill>> watchAll() {
    return db
        .stream('SELECT * FROM aichat_skills ORDER BY trigger')
        .map((rows) => rows.map((r) => AichatSkill.fromDbMap(r.cast<String, dynamic>())).toList());
  }
}
