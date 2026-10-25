import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/aichat/services/agent_loop.dart';
import 'package:mydatastudio/modules/aichat/services/chat_tool_support.dart';

/// Glue between the agent loop and the chat page: how tool turns are stored
/// and restored, which items an answer used, and what the activity line says.

final _call = {
  'id': 'c1',
  'type': 'function',
  'function': {'name': 'search', 'arguments': '{"query": "lease", "from": "Sarah"}'},
};

final _result = jsonEncode({
  'total': 2,
  'results': [
    {'id': 'email:e1', 'type': 'email', 'title': 'Lease renewal', 'date': '2024-04-02'},
    {'id': 'file:f9', 'type': 'file', 'title': 'lease.pdf', 'date': '2024-04-05'},
  ],
});

void main() {
  group('storage', () {
    test('a tool-call turn and its result survive a save and reload', () {
      final assistant = {'role': 'assistant', 'content': null, 'tool_calls': [_call]};
      final tool = {'role': 'tool', 'tool_call_id': 'c1', 'content': _result};

      final stored = [toStoredToolMessage(assistant), toStoredToolMessage(tool)];
      // Distinct roles, so an old build reading the table never mistakes a
      // tool turn for an assistant reply.
      expect(stored.map((s) => s.role), ['tool_call', 'tool']);

      final restored = [
        for (final s in stored) fromStoredToolMessage(s.role, s.content)!,
      ];
      expect(restored[0]['role'], 'assistant');
      expect(restored[0]['tool_calls'], [_call]);
      expect(restored[1], tool);
    });

    test('ordinary roles are not tool messages', () {
      expect(fromStoredToolMessage('assistant', 'hi'), isNull);
      expect(fromStoredToolMessage('user', 'hi'), isNull);
    });

    test('a corrupt stored tool row is skipped, not fatal', () {
      expect(fromStoredToolMessage('tool_call', '{not json'), isNull);
    });
  });

  group('sources', () {
    test('items from search results become sources, deduplicated', () {
      final steps = [
        {'role': 'assistant', 'content': null, 'tool_calls': [_call]},
        {'role': 'tool', 'tool_call_id': 'c1', 'content': _result},
        {'role': 'tool', 'tool_call_id': 'c2', 'content': _result},
      ];
      final sources = sourcesFromToolTurn(steps);
      expect(sources.map((s) => s.id), ['email:e1', 'file:f9']);
      expect(sources.first.title, 'Lease renewal');
    });

    test('get_item and list_items results count too', () {
      final steps = [
        {
          'role': 'tool',
          'content': jsonEncode({'id': 'email:e7', 'type': 'email', 'subject': 'Invoice'}),
        },
        {
          'role': 'tool',
          'content': jsonEncode({
            'items': [
              {'id': 'file:f1', 'title': 'W-2.pdf'},
            ],
          }),
        },
      ];
      expect(sourcesFromToolTurn(steps).map((s) => s.id), ['email:e7', 'file:f1']);
    });

    test('errors and non-JSON results contribute nothing', () {
      final steps = [
        {'role': 'tool', 'content': '{"error": "No email with id \\"x\\"."}'},
        {'role': 'tool', 'content': 'not json'},
      ];
      expect(sourcesFromToolTurn(steps), isEmpty);
    });

    test('sources are capped so a broad search does not bury the answer', () {
      final many = jsonEncode({
        'results': [
          for (var i = 0; i < 30; i++) {'id': 'email:$i', 'title': 't$i'},
        ],
      });
      expect(
        sourcesFromToolTurn([{'role': 'tool', 'content': many}]),
        hasLength(maxSourcesShown),
      );
    });
  });

  group('activity line', () {
    test('describes a search with its filters', () {
      final text = describeActivity(
        ToolActivity('search', '{"query": "lease", "from": "Sarah", "sources": ["email"]}'),
      );
      expect(text, 'Searching emails for “lease” from Sarah…');
    });

    test('describes the other tools plainly', () {
      expect(describeActivity(ToolActivity('get_item', '{"id": "email:1"}')), 'Opening an item…');
      expect(describeActivity(ToolActivity('list_collections', '{}')), 'Checking your archives…');
      expect(describeActivity(ToolActivity('mystery', 'garbage')), 'Using mystery…');
    });
  });
}
