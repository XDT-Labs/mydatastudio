import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/aichat/services/tools/archive_tool.dart';
import 'package:mydatastudio/modules/aichat/services/tools/tool_registry.dart';
import 'package:mydatastudio/modules/search/services/tools/search_tools.dart';

/// Email-only tools for the chat model.
class EmailToolProvider implements ToolProvider {
  EmailToolProvider(this.database);

  final AppDatabase database;

  @override
  List<ArchiveTool> get tools => [GetEmailThreadTool(database)];
}

class GetEmailThreadTool extends ArchiveTool {
  GetEmailThreadTool(this.database);

  final AppDatabase database;

  /// A thread longer than this is cut to its most recent messages.
  static const maxMessages = 30;

  @override
  String get name => 'get_email_thread';

  @override
  String get description =>
      'Get every message in the conversation an email belongs to, oldest first.';

  @override
  Map<String, Object?> get parameters => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'Id of any email in the thread.'},
    },
    'required': ['id'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> run(Map<String, Object?> args) async {
    final raw = args['id'] as String;
    final id = parseItemId(raw).id;
    final anchor = await database.select(
      'SELECT thread_id, collection_id FROM emails '
      'WHERE id = ? AND is_deleted = 0 LIMIT 1',
      [id],
    );
    if (anchor.isEmpty) return ToolResult.error('No email with id "$raw".');

    final threadId = anchor.first['thread_id'] as String?;
    // Thread ids come from the provider, so they're only unique within one
    // collection (account).
    final rows = threadId == null || threadId.isEmpty
        ? await database.select(
            'SELECT id, "from", date, subject, snippet FROM emails WHERE id = ?',
            [id],
          )
        : await database.select(
            'SELECT * FROM (SELECT id, "from", date, subject, snippet FROM emails '
            'WHERE thread_id = ? AND collection_id = ? AND is_deleted = 0 '
            'ORDER BY date DESC LIMIT ?) ORDER BY date ASC',
            [threadId, anchor.first['collection_id'], maxMessages],
          );

    return ToolResult.ok({
      'messages': [
        for (final row in rows)
          {
            'id': 'email:${row['id']}',
            'from': row['from'],
            'date': toolDate(
              DateTime.fromMillisecondsSinceEpoch((row['date'] as num).toInt()),
            ),
            'subject': row['subject'],
            if ((row['snippet'] as String?)?.trim().isNotEmpty ?? false)
              'snippet': _clip(row['snippet'] as String),
          },
      ],
    });
  }

  static String _clip(String text) {
    final t = text.trim();
    return t.length <= ToolBudgets.snippetChars
        ? t
        : '${t.substring(0, ToolBudgets.snippetChars - 1)}…';
  }
}
