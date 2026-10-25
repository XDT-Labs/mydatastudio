import 'dart:convert';

import 'package:mydatastudio/modules/aichat/services/agent_loop.dart';

/// Stored role for an assistant turn that only called tools.
///
/// Not `assistant`: code that predates tools reads every `assistant` row as a
/// reply to show, and a tool call has no text to show.
const storedToolCallRole = 'tool_call';
const storedToolResultRole = 'tool';

/// How many cited items are listed under one answer.
const maxSourcesShown = 8;

/// A tool-loop message as a row for `aichat_conversation_history`
/// (`role`, `content`). No schema change: the JSON goes in `content`.
({String role, String content}) toStoredToolMessage(Map<String, dynamic> m) {
  if (m['tool_calls'] != null) {
    return (
      role: storedToolCallRole,
      content: jsonEncode({'content': m['content'], 'tool_calls': m['tool_calls']}),
    );
  }
  return (
    role: storedToolResultRole,
    content: jsonEncode({'tool_call_id': m['tool_call_id'], 'content': m['content']}),
  );
}

/// The history message for a stored tool row, or null if [role] isn't one
/// (or the row can't be read, which skips it rather than failing the load).
Map<String, dynamic>? fromStoredToolMessage(String role, String content) {
  if (role != storedToolCallRole && role != storedToolResultRole) return null;
  try {
    final data = jsonDecode(content) as Map<String, dynamic>;
    if (role == storedToolCallRole) {
      return {
        'role': 'assistant',
        'content': data['content'],
        'tool_calls': data['tool_calls'],
      };
    }
    return {
      'role': 'tool',
      'tool_call_id': data['tool_call_id'],
      'content': data['content'],
    };
  } catch (_) {
    return null;
  }
}

/// An archive item a tool returned, listed under the answer that used it.
class ToolSource {
  const ToolSource({required this.id, required this.title, this.date});

  /// `email:<id>` or `file:<id>`, as the tools return it.
  final String id;
  final String title;
  final String? date;

  bool get isEmail => id.startsWith('email:');
  String get rowId => id.substring(id.indexOf(':') + 1);
}

/// Every item the tool results in [steps] returned, first seen first.
///
/// "Returned" rather than "cited": a small model's answer can't be relied on
/// to name ids, but every item it was shown is something the user can check.
List<ToolSource> sourcesFromToolTurn(List<Map<String, dynamic>> steps) {
  final seen = <String>{};
  final sources = <ToolSource>[];
  void add(Object? item) {
    if (item is! Map || sources.length >= maxSourcesShown) return;
    final id = item['id'];
    if (id is! String || !id.contains(':') || !seen.add(id)) return;
    final title = item['title'] ?? item['subject'] ?? item['name'] ?? id;
    sources.add(ToolSource(id: id, title: '$title', date: item['date'] as String?));
  }

  for (final m in steps) {
    if (m['role'] != 'tool') continue;
    final Object? data;
    try {
      data = jsonDecode(m['content'] as String? ?? '');
    } catch (_) {
      continue;
    }
    if (data is! Map || data.containsKey('error')) continue;
    for (final key in const ['results', 'items', 'messages']) {
      final list = data[key];
      if (list is List) list.forEach(add);
    }
    add(data); // get_item returns the item itself
  }
  return sources;
}

/// The one-line status shown while a tool runs.
String describeActivity(ToolActivity activity) {
  Map<String, dynamic> args;
  try {
    args = jsonDecode(activity.argumentsJson) as Map<String, dynamic>;
  } catch (_) {
    args = const {};
  }
  switch (activity.name) {
    case 'search':
      final sources = (args['sources'] as List?)?.cast<String>() ?? const [];
      final where = switch (sources) {
        ['email'] => 'emails',
        ['file'] => 'files',
        _ => 'your archive',
      };
      final query = (args['query'] as String?)?.trim();
      final parts = [
        'Searching $where',
        if (query != null && query.isNotEmpty && query != '*') 'for “$query”',
        if (args['from'] case final String from when from.isNotEmpty) 'from $from',
      ];
      return '${parts.join(' ')}…';
    case 'get_item':
      return 'Opening an item…';
    case 'get_email_thread':
      return 'Reading the email thread…';
    case 'list_items':
      return args['source'] == 'file' ? 'Listing files…' : 'Listing emails…';
    case 'list_collections':
      return 'Checking your archives…';
    default:
      return 'Using ${activity.name}…';
  }
}
