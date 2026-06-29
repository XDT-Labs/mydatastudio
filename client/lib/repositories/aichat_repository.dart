import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/aichat_conversation.dart';
import 'package:mydatastudio/models/tables/aichat_message.dart';
import 'package:uuid/uuid.dart';

class AichatRepository {
  final AppDatabase db;
  static const _uuid = Uuid();

  AichatRepository(this.db);

  Future<AichatConversation> createConversation({
    required String name,
    String? model,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      'INSERT INTO aichat_conversations (id, name, model, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [id, name, model, now, now],
    );
    return AichatConversation(
      id: id,
      name: name,
      model: model,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  Future<void> updateConversation(
    String id, {
    String? name,
    String? model,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (name != null && model != null) {
      await db.execute(
        'UPDATE aichat_conversations SET name = ?, model = ?, updated_at = ? WHERE id = ?',
        [name, model, now, id],
      );
    } else if (name != null) {
      await db.execute(
        'UPDATE aichat_conversations SET name = ?, updated_at = ? WHERE id = ?',
        [name, now, id],
      );
    } else if (model != null) {
      await db.execute(
        'UPDATE aichat_conversations SET model = ?, updated_at = ? WHERE id = ?',
        [model, now, id],
      );
    }
  }

  Stream<List<AichatConversation>> watchConversations() {
    return db
        .stream('SELECT * FROM aichat_conversations ORDER BY updated_at DESC')
        .map(
          (rows) =>
              rows
                  .map(
                    (r) => AichatConversation.fromDbMap(
                      r.cast<String, dynamic>(),
                    ),
                  )
                  .toList(),
        );
  }

  Future<AichatMessage> addMessage({
    required String conversationId,
    required String role,
    required String content,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.execute(
      'INSERT INTO aichat_conversation_history '
      '(id, conversation_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)',
      [id, conversationId, role, content, now],
    );
    await db.execute(
      'UPDATE aichat_conversations SET updated_at = ? WHERE id = ?',
      [now, conversationId],
    );
    return AichatMessage(
      id: id,
      conversationId: conversationId,
      role: role,
      content: content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  Future<List<AichatMessage>> getMessages(String conversationId) async {
    final rows = await db.select(
      'SELECT * FROM aichat_conversation_history '
      'WHERE conversation_id = ? ORDER BY created_at ASC',
      [conversationId],
    );
    return rows
        .map(
          (r) => AichatMessage.fromDbMap(r.cast<String, dynamic>()),
        )
        .toList();
  }

  Future<void> deleteConversation(String id) async {
    await db.execute(
      'DELETE FROM aichat_conversations WHERE id = ?',
      [id],
    );
  }
}
