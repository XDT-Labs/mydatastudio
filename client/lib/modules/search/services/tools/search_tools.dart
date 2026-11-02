import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/aichat/services/tools/archive_tool.dart';
import 'package:mydatastudio/modules/aichat/services/tools/tool_registry.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/archive_search.dart';
import 'package:mydatastudio/modules/search/services/retrievers/vector_retriever.dart';

/// Archive-wide tools: search, open an item, browse by date, list archives.
///
/// They span emails and files, so they live with search rather than in either
/// module. The names and argument shapes are the ones the Phase 0 eval measured
/// (aiserver/evals/tools.json); change them and re-run it.
class SearchToolProvider implements ToolProvider {
  SearchToolProvider(this.database, this.embedder);

  final AppDatabase database;
  final QueryEmbedder embedder;

  @override
  List<ArchiveTool> get tools => [
    SearchTool(database, embedder),
    GetItemTool(database),
    ListItemsTool(database),
    ListCollectionsTool(database),
  ];
}

final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// `YYYY-MM-DD` for the model; local time, because that's the day the user means.
String toolDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime _fromMs(Object? ms) =>
    DateTime.fromMillisecondsSinceEpoch((ms as num).toInt());

String? _clip(String? text, int max) {
  final t = text?.trim();
  if (t == null || t.isEmpty) return null;
  return t.length <= max ? t : '${t.substring(0, max - 1)}…';
}

/// Splits `email:123` into its source and row id. A bare id is accepted too,
/// since the model sometimes drops the prefix.
({SearchResultType? type, String id}) parseItemId(String raw) {
  final colon = raw.indexOf(':');
  if (colon > 0) {
    final prefix = raw.substring(0, colon);
    for (final type in SearchResultType.values) {
      if (type.name == prefix) return (type: type, id: raw.substring(colon + 1));
    }
  }
  return (type: null, id: raw);
}

class SearchTool extends ArchiveTool {
  SearchTool(this.database, this.embedder);

  final AppDatabase database;
  final QueryEmbedder embedder;

  @override
  String get name => 'search';

  @override
  String get description =>
      "Search the user's archived emails and files by keyword and meaning. "
      'Returns matching items with id, title, sender, date and a short snippet, '
      'plus the total number of matches.';

  @override
  Map<String, Object?> get parameters => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'What to look for, in plain words. Do not put sender names or dates '
            'here; use the other arguments.',
      },
      'sources': {
        'type': 'array',
        'items': {'type': 'string', 'enum': ['email', 'file']},
        'description': 'Limit to these archives. Omit to search everything.',
      },
      'from': {'type': 'string', 'description': 'Sender name or email address.'},
      'to': {'type': 'string', 'description': 'Recipient name or email address.'},
      'after': {
        'type': 'string',
        'description': 'Only items on or after this date, YYYY-MM-DD.',
      },
      'before': {
        'type': 'string',
        'description': 'Only items before this date, YYYY-MM-DD.',
      },
      'limit': {
        'type': 'integer',
        'minimum': 1,
        'maximum': ToolBudgets.maxSearchLimit,
        'description': 'Maximum results, default ${ToolBudgets.defaultSearchLimit}.',
      },
    },
    'required': ['query'],
    'additionalProperties': false,
  };

  /// The search-box query equivalent to [args], so a tool search applies the
  /// same hard filters the user would get typing `from:sarah` themselves.
  static String buildQuery(Map<String, Object?> args) {
    final parts = <String>[];
    final sources = (args['sources'] as List?)?.cast<String>().toSet();
    if (sources != null && sources.length == 1) {
      parts.add('type:${sources.single}');
    }
    for (final field in const ['from', 'to']) {
      final value = _filterValue(args[field]);
      if (value != null) parts.add('$field:$value');
    }
    for (final field in const ['after', 'before']) {
      final value = args[field] as String?;
      if (value != null && _isoDate.hasMatch(value)) parts.add('$field:$value');
    }
    final text = (args['query'] as String? ?? '').trim();
    // Recorded in Phase 0: "everything X sent me" comes back as query "*".
    if (text.isNotEmpty && text != '*') parts.add(text);
    return parts.join(' ');
  }

  /// A filter value that can't break out of its field: quotes are the only
  /// delimiter the tokenizer knows, so they're removed, and a value with
  /// spaces is quoted.
  static String? _filterValue(Object? raw) {
    final cleaned = (raw as String?)?.replaceAll('"', '').trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    return cleaned.contains(RegExp(r'\s')) ? '"$cleaned"' : cleaned;
  }

  @override
  Future<ToolResult> run(Map<String, Object?> args) async {
    for (final field in const ['after', 'before']) {
      final value = args[field] as String?;
      if (value != null && !_isoDate.hasMatch(value)) {
        return ToolResult.error('"$field" must be YYYY-MM-DD, got "$value".');
      }
    }
    final limit =
        (args['limit'] as num?)?.toInt() ?? ToolBudgets.defaultSearchLimit;
    final query = buildQuery(args);
    if (query.isEmpty) {
      return ToolResult.error('Give a query or at least one filter.');
    }

    final retrieval = await ArchiveSearch(database, embedder).retrieve(query);
    final top = retrieval.top(limit);
    return ToolResult.ok({
      'query': query,
      'total': top.emailTotal + top.fileTotal,
      'shown': top.results.length,
      'results': [for (final r in top.results) _hit(r)],
    });
  }

  Map<String, Object?> _hit(SearchResult r) => {
    'id': r.key,
    'type': r.type.name,
    'title': r.title,
    if (r.isEmail && r.subtitle != null) 'from': r.subtitle,
    if (!r.isEmail && r.subtitle != null) 'path': r.subtitle,
    if (r.date != null) 'date': toolDate(r.date!),
    if (_clip(r.snippet, ToolBudgets.snippetChars) case final snippet?)
      'snippet': snippet,
    if (r.citation?.page case final page?) 'page': page,
  };
}

class GetItemTool extends ArchiveTool {
  GetItemTool(this.database);

  final AppDatabase database;

  @override
  String get name => 'get_item';

  @override
  String get description =>
      'Get the full text and details of one email or file, by the id a search returned.';

  @override
  Map<String, Object?> get parameters => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'Item id from a search result.'},
    },
    'required': ['id'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> run(Map<String, Object?> args) async {
    final raw = args['id'] as String;
    final ref = parseItemId(raw);
    if (ref.type != SearchResultType.file) {
      final email = await _email(ref.id);
      if (email != null) return ToolResult.ok(email);
    }
    if (ref.type != SearchResultType.email) {
      final file = await _file(ref.id);
      if (file != null) return ToolResult.ok(file);
    }
    return ToolResult.error('No email or file with id "$raw".');
  }

  Future<Map<String, Object?>?> _email(String id) async {
    final rows = await database.select(
      'SELECT id, subject, "from", "to", cc, date, has_attachments, '
      "COALESCE(NULLIF(body_text, ''), NULLIF(plain_body, ''), snippet, '') AS text "
      'FROM emails WHERE id = ? AND is_deleted = 0 LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'id': 'email:$id',
      'type': 'email',
      'subject': row['subject'],
      'from': row['from'],
      'to': row['to'],
      if ((row['cc'] as String?)?.isNotEmpty ?? false) 'cc': row['cc'],
      'date': toolDate(_fromMs(row['date'])),
      'has_attachments': row['has_attachments'] == 1,
      ..._text(row['text'] as String? ?? ''),
    };
  }

  Future<Map<String, Object?>?> _file(String id) async {
    final rows = await database.select(
      'SELECT id, name, path, content_type, date_created, size, description '
      'FROM files WHERE id = ? AND is_deleted = 0 LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final chunks = await database.select(
      'SELECT text FROM file_chunks WHERE file_id = ? ORDER BY chunk_index',
      [id],
    );
    return {
      'id': 'file:$id',
      'type': 'file',
      'name': row['name'],
      'path': row['path'],
      'content_type': row['content_type'],
      'date': toolDate(_fromMs(row['date_created'])),
      if ((row['description'] as String?)?.isNotEmpty ?? false)
        'description': row['description'],
      ..._text(chunks.map((c) => c['text'] as String).join('\n')),
    };
  }

  Map<String, Object?> _text(String text) {
    if (text.isEmpty) return const {};
    if (text.length <= ToolBudgets.itemTextChars) return {'text': text};
    return {
      'text': text.substring(0, ToolBudgets.itemTextChars),
      'truncated': true,
    };
  }
}

class ListItemsTool extends ArchiveTool {
  ListItemsTool(this.database);

  final AppDatabase database;

  @override
  String get name => 'list_items';

  @override
  String get description =>
      'List emails or files by date, without a search query. '
      "Use for 'what came in last week' style questions.";

  @override
  Map<String, Object?> get parameters => {
    'type': 'object',
    'properties': {
      'source': {'type': 'string', 'enum': ['email', 'file']},
      'after': {'type': 'string', 'description': 'YYYY-MM-DD'},
      'before': {'type': 'string', 'description': 'YYYY-MM-DD'},
      'sort': {'type': 'string', 'enum': ['newest', 'oldest']},
      'limit': {'type': 'integer', 'minimum': 1, 'maximum': ToolBudgets.maxSearchLimit},
    },
    'required': ['source'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> run(Map<String, Object?> args) async {
    final isEmail = args['source'] == 'email';
    final dateCol = isEmail ? 'date' : 'date_created';
    // The same visibility rules as SearchFilters, so a listed item is one
    // search could also have found.
    final where = isEmail
        ? <String>['is_deleted = 0']
        : <String>['is_deleted = 0', 'is_inline = 0'];
    final params = <Object?>[];
    for (final (field, op) in const [('after', '>='), ('before', '<')]) {
      final value = args[field] as String?;
      if (value == null) continue;
      if (!_isoDate.hasMatch(value)) {
        return ToolResult.error('"$field" must be YYYY-MM-DD, got "$value".');
      }
      where.add('$dateCol $op ?');
      params.add(DateTime.parse(value).millisecondsSinceEpoch);
    }
    final order = args['sort'] == 'oldest' ? 'ASC' : 'DESC';
    final limit =
        (args['limit'] as num?)?.toInt() ?? ToolBudgets.defaultSearchLimit;
    final table = isEmail ? 'emails' : 'files';
    final columns = isEmail
        ? 'id, subject AS title, "from", date AS d, snippet'
        : 'id, name AS title, path, date_created AS d, description AS snippet';
    final clause = where.join(' AND ');

    final rows = await database.select(
      'SELECT $columns FROM $table WHERE $clause ORDER BY $dateCol $order LIMIT ?',
      [...params, limit],
    );
    final count = await database.select(
      'SELECT COUNT(*) AS n FROM $table WHERE $clause',
      params,
    );
    return ToolResult.ok({
      'total': count.first['n'],
      'shown': rows.length,
      'items': [
        for (final row in rows)
          {
            'id': '${isEmail ? 'email' : 'file'}:${row['id']}',
            'title': row['title'],
            if (isEmail) 'from': row['from'] else 'path': row['path'],
            'date': toolDate(_fromMs(row['d'])),
            if (_clip(row['snippet'] as String?, ToolBudgets.snippetChars)
                case final snippet?)
              'snippet': snippet,
          },
      ],
    });
  }
}

class ListCollectionsTool extends ArchiveTool {
  ListCollectionsTool(this.database);

  final AppDatabase database;

  @override
  String get name => 'list_collections';

  @override
  String get description =>
      'List the archives the user has imported (email accounts, drives, folders), '
      'with item counts.';

  @override
  Map<String, Object?> get parameters => {
    'type': 'object',
    'properties': <String, Object?>{},
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> run(Map<String, Object?> args) async {
    final rows = await database.select(
      'SELECT c.name, c.type, c.scanner, '
      '(SELECT COUNT(*) FROM emails e WHERE e.collection_id = c.id AND e.is_deleted = 0) + '
      '(SELECT COUNT(*) FROM files f WHERE f.collection_id = c.id '
      'AND f.is_deleted = 0 AND f.is_inline = 0) AS items '
      'FROM collections c ORDER BY c.name',
    );
    return ToolResult.ok({
      'collections': [
        for (final row in rows)
          {
            'name': row['name'],
            'type': row['type'],
            'source': row['scanner'],
            'items': row['items'],
          },
      ],
    });
  }
}
