import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/aichat/services/agent_loop.dart';
import 'package:mydatastudio/modules/aichat/services/tools/archive_tool.dart';
import 'package:mydatastudio/modules/aichat/services/tools/tool_registry.dart';

/// The agent loop decides how many model calls one user message costs and what
/// history the next turn sees. Its limits are what keep a 12B model from
/// looping, and its history is what the Gemma template has to accept.

class _SearchTool extends ArchiveTool {
  int calls = 0;

  @override
  String get name => 'search';
  @override
  String get description => 'Search.';
  @override
  Map<String, Object?> get parameters => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
    },
    'required': ['query'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> run(Map<String, Object?> args) async {
    calls++;
    return ToolResult.ok({'total': 1});
  }
}

class _Provider implements ToolProvider {
  _Provider(this.tools);
  @override
  final List<ArchiveTool> tools;
}

Map<String, dynamic> _call(String id, String name, Map<String, Object?> args) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(args)},
};

/// Replays scripted turns and records every request it was sent.
class _ScriptedModel {
  _ScriptedModel(this.turns);

  final List<AssistantTurn> turns;
  final requests = <({List<Map<String, dynamic>> messages, bool offeredTools})>[];

  Future<AssistantTurn?> call(
    List<Map<String, dynamic>> messages,
    List<Map<String, Object?>>? tools,
  ) async {
    requests.add((
      messages: [for (final m in messages) Map<String, dynamic>.from(m)],
      offeredTools: tools != null,
    ));
    final i = requests.length - 1;
    return i < turns.length ? turns[i] : turns.last;
  }
}

final _user = {'role': 'user', 'content': 'find the lease'};

void main() {
  late _SearchTool search;
  late ToolRegistry registry;

  setUp(() {
    search = _SearchTool();
    registry = ToolRegistry([_Provider([search])]);
  });

  test('a reply with no tool call is one request', () async {
    final model = _ScriptedModel([AssistantTurn(content: '51')]);
    final result = await AgentLoop(registry: registry, transport: model.call)
        .run([_user]);

    expect(model.requests, hasLength(1));
    expect(model.requests.single.offeredTools, isTrue);
    expect(result.finalText, '51');
    expect(result.added, [
      {'role': 'assistant', 'content': '51'},
    ]);
  });

  test('a tool call runs, its result is sent back, then the answer', () async {
    final model = _ScriptedModel([
      AssistantTurn(toolCalls: [_call('c1', 'search', {'query': 'lease'})]),
      AssistantTurn(content: 'Your lease renews May 1.'),
    ]);
    final result = await AgentLoop(registry: registry, transport: model.call)
        .run([_user]);

    expect(search.calls, 1);
    final second = model.requests[1].messages;
    expect(second[1]['tool_calls'], isNotEmpty);
    expect(second[2]['role'], 'tool');
    expect(second[2]['tool_call_id'], 'c1');
    expect(jsonDecode(second[2]['content'] as String)['total'], 1);
    expect(result.finalText, 'Your lease renews May 1.');
    // Tool turns are part of what gets saved, so a reload can continue.
    expect(result.added.map((m) => m['role']), ['assistant', 'tool', 'assistant']);
  });

  test('every call in a multi-call turn gets its own result, in order', () async {
    final model = _ScriptedModel([
      AssistantTurn(toolCalls: [
        _call('a', 'search', {'query': 'lease'}),
        _call('b', 'search', {'query': 'rent'}),
      ]),
      AssistantTurn(content: 'done'),
    ]);
    await AgentLoop(registry: registry, transport: model.call).run([_user]);
    final ids = model.requests[1].messages
        .where((m) => m['role'] == 'tool')
        .map((m) => m['tool_call_id']);
    expect(ids, ['a', 'b']);
  });

  test('after four tool calls the model must answer without tools', () async {
    // A model that never stops calling tools.
    final model = _ScriptedModel([
      AssistantTurn(toolCalls: [_call('c', 'search', {'query': 'again'})]),
    ]);
    final result = await AgentLoop(registry: registry, transport: model.call)
        .run([_user]);

    expect(search.calls, ToolBudgets.maxCallsPerTurn);
    expect(model.requests.last.offeredTools, isFalse);
    expect(model.requests.where((r) => r.offeredTools), hasLength(ToolBudgets.maxCallsPerTurn));
    // The forced final turn still produced *something* for the user.
    expect(result.added.last['role'], 'assistant');
  });

  test('the same tool failing twice in a row ends the tool use', () async {
    final model = _ScriptedModel([
      AssistantTurn(toolCalls: [_call('c1', 'search', {'q': 'bad arg'})]),
      AssistantTurn(toolCalls: [_call('c2', 'search', {'q': 'bad again'})]),
      AssistantTurn(content: "I couldn't search your archive."),
    ]);
    final result = await AgentLoop(registry: registry, transport: model.call)
        .run([_user]);

    expect(search.calls, 0);
    expect(model.requests, hasLength(3));
    expect(model.requests[2].offeredTools, isFalse);
    expect(result.finalText, "I couldn't search your archive.");
  });

  test('one bad call followed by a fixed one keeps going', () async {
    final model = _ScriptedModel([
      AssistantTurn(toolCalls: [_call('c1', 'search', {'q': 'bad arg'})]),
      AssistantTurn(toolCalls: [_call('c2', 'search', {'query': 'lease'})]),
      AssistantTurn(content: 'found it'),
    ]);
    await AgentLoop(registry: registry, transport: model.call).run([_user]);
    expect(search.calls, 1);
    expect(model.requests[2].offeredTools, isTrue);
  });

  test('the per-turn output budget follows from the call cap and result cap', () {
    // No separate per-turn check exists: four calls at most, each result at
    // most maxResultChars, is the turn budget. Keep the numbers consistent.
    expect(
      ToolBudgets.maxCallsPerTurn * ToolBudgets.maxResultChars,
      lessThanOrEqualTo(ToolBudgets.maxTurnResultChars),
    );
  });

  test('cancelling between steps runs no further tools or requests', () async {
    var cancelled = false;
    final model = _ScriptedModel([
      AssistantTurn(toolCalls: [_call('c1', 'search', {'query': 'lease'})]),
      AssistantTurn(content: 'never sent'),
    ]);
    final result = await AgentLoop(
      registry: registry,
      transport: (messages, tools) async {
        final turn = await model.call(messages, tools);
        cancelled = true; // user pressed stop while this turn streamed
        return turn;
      },
      isCancelled: () => cancelled,
    ).run([_user]);

    expect(search.calls, 0);
    expect(model.requests, hasLength(1));
    expect(result.cancelled, isTrue);
    // A tool-call turn with no results would break the template next time.
    expect(result.added.where((m) => m['tool_calls'] != null), isEmpty);
  });

  test('a failed request (null turn) ends the loop with what was finished', () async {
    final result = await AgentLoop(
      registry: registry,
      transport: (_, _) async => null,
    ).run([_user]);
    expect(result.finalText, isNull);
    expect(result.added, isEmpty);
  });

  test('activity is reported for each call, start and finish', () async {
    final events = <String>[];
    final model = _ScriptedModel([
      AssistantTurn(toolCalls: [_call('c1', 'search', {'query': 'lease'})]),
      AssistantTurn(content: 'ok'),
    ]);
    await AgentLoop(
      registry: registry,
      transport: model.call,
      onActivity: (a) => events.add('${a.name}:${a.finished}:${a.isError}'),
    ).run([_user]);
    expect(events, ['search:false:false', 'search:true:false']);
  });
}
