import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/aichat/services/tools/archive_tool.dart';
import 'package:mydatastudio/modules/aichat/services/tools/tool_registry.dart';

/// The registry is the boundary between model output and our code. Every call
/// it receives was written by the model, so a bad name, bad JSON or bad
/// arguments must come back as an error the model can read and fix, never as
/// an exception that kills the chat turn.

class _EchoTool extends ArchiveTool {
  _EchoTool({this.payloadChars = 0, this.throws = false});

  final int payloadChars;
  final bool throws;
  Map<String, Object?>? lastArgs;

  @override
  String get name => 'echo';

  @override
  String get description => 'Echoes its arguments.';

  @override
  Map<String, Object?> get parameters => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
      'sources': {
        'type': 'array',
        'items': {'type': 'string', 'enum': ['email', 'file']},
      },
      'limit': {'type': 'integer', 'minimum': 1, 'maximum': 20},
    },
    'required': ['query'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> run(Map<String, Object?> args) async {
    if (throws) throw StateError('database closed');
    lastArgs = args;
    return ToolResult.ok({'args': args, 'pad': 'x' * payloadChars});
  }
}

class _PatternTool extends _EchoTool {
  @override
  Map<String, Object?> get parameters => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'pattern': '^a'},
    },
  };
}

class _Provider implements ToolProvider {
  _Provider(this.tools);
  @override
  final List<ArchiveTool> tools;
}

void main() {
  group('calls', () {
    test('valid arguments reach the tool and its result comes back', () async {
      final tool = _EchoTool();
      final registry = ToolRegistry([_Provider([tool])]);
      final result = await registry.call('echo', '{"query": "lease", "limit": 3}');
      expect(result.isError, isFalse);
      expect(tool.lastArgs, {'query': 'lease', 'limit': 3});
    });

    test('an unknown tool names the ones that exist', () async {
      final registry = ToolRegistry([_Provider([_EchoTool()])]);
      final result = await registry.call('serch', '{}');
      expect(result.isError, isTrue);
      expect(result.data['error'], contains('echo'));
    });

    test('arguments that are not JSON are an error, not an exception', () async {
      final registry = ToolRegistry([_Provider([_EchoTool()])]);
      final result = await registry.call('echo', '{query: lease');
      expect(result.isError, isTrue);
    });

    test('empty arguments are treated as {}', () async {
      final registry = ToolRegistry([_Provider([_EchoTool()])]);
      final result = await registry.call('echo', '');
      // Then fails validation: query is required.
      expect(result.data['error'], contains('"query" is required'));
    });

    test('a tool that throws becomes an error result', () async {
      final registry = ToolRegistry([_Provider([_EchoTool(throws: true)])]);
      final result = await registry.call('echo', '{"query": "x"}');
      expect(result.isError, isTrue);
      expect(result.data['error'], contains('database closed'));
    });

    test('an oversized result is refused rather than cut mid-JSON', () async {
      final registry = ToolRegistry([
        _Provider([_EchoTool(payloadChars: ToolBudgets.maxResultChars)]),
      ]);
      final result = await registry.call('echo', '{"query": "x"}');
      expect(result.isError, isTrue);
      expect(() => jsonDecode(result.toJson()), returnsNormally);
    });

    test('duplicate tool names are a startup error', () {
      expect(
        () => ToolRegistry([_Provider([_EchoTool(), _EchoTool()])]),
        throwsStateError,
      );
    });

    test('definitions are OpenAI function tools', () {
      final defs = ToolRegistry([_Provider([_EchoTool()])]).definitions();
      expect(defs.single['type'], 'function');
      expect((defs.single['function'] as Map)['name'], 'echo');
    });
  });

  group('argument validation', () {
    final schema = _EchoTool().parameters;
    List<String> check(Map<String, Object?> args) =>
        ToolArgumentValidator.validate(args, schema);

    test('accepts matching arguments', () {
      expect(check({'query': 'x', 'sources': ['email'], 'limit': 20}), isEmpty);
    });

    test('rejects a missing required argument', () {
      expect(check({'limit': 3}), contains('"query" is required'));
    });

    test('rejects an argument the tool does not take', () {
      // Recorded in the Phase 0 router eval: the model invented `sort` for
      // `search`. Passing it through silently would hide that.
      expect(check({'query': 'x', 'sort': 'newest'}).single, contains('sort'));
    });

    test('rejects wrong types, bad enum values and out-of-range numbers', () {
      expect(check({'query': 3}).single, contains('string'));
      expect(check({'query': 'x', 'sources': ['photos']}).single, contains('one of'));
      // Recorded in the Phase 0 forced eval: limit 100 and 1000.
      expect(check({'query': 'x', 'limit': 100}).single, contains('<= 20'));
    });

    test('a whole-number double counts as an integer', () {
      // jsonDecode turns 8.0 into a double; the model meant 8.
      expect(check({'query': 'x', 'limit': 8.0}), isEmpty);
    });

    test('a schema keyword the validator does not know fails at startup', () {
      // Checked when the registry is built, not on the first call that
      // happens to pass that argument.
      expect(
        () => ToolRegistry([_Provider([_PatternTool()])]),
        throwsArgumentError,
      );
    });
  });
}
