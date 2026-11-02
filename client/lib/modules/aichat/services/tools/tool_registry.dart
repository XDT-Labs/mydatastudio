import 'dart:convert';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/modules/aichat/services/tools/archive_tool.dart';

/// Limits for tool use in one chat turn (docs/plans/llm-tools.md §3).
///
/// One place for all of them, so the agent loop, the tools and the tests agree.
class ToolBudgets {
  /// Small models get unreliable when chaining calls, and every step is
  /// another full generation.
  static const maxCallsPerTurn = 4;
  static const defaultSearchLimit = 8;
  static const maxSearchLimit = 20;
  static const snippetChars = 200;

  /// Full text returned by `get_item`; about 1,500 tokens.
  static const itemTextChars = 6000;

  /// One tool result (~2,000 tokens). Bigger results are refused, not cut,
  /// because cutting JSON breaks it.
  static const maxResultChars = 8000;

  /// All tool output in one user turn (~8,000 tokens of the 32k context).
  /// Not enforced separately: [maxCallsPerTurn] × [maxResultChars] is this
  /// budget, and a test keeps the three consistent.
  static const maxTurnResultChars = 32000;
}

/// Every tool the model may call, and the one way to call them.
///
/// Calls arrive from the model, so nothing about them is trusted: the name
/// may not exist, the arguments may not be JSON, and they may not match the
/// schema. Each of those becomes a [ToolResult.error] the model can read and
/// correct, never an exception.
class ToolRegistry {
  ToolRegistry(List<ToolProvider> providers) {
    for (final provider in providers) {
      for (final tool in provider.tools) {
        if (_tools.containsKey(tool.name)) {
          throw StateError('Duplicate tool name: ${tool.name}');
        }
        ToolArgumentValidator.checkSchema(tool.name, tool.parameters);
        _tools[tool.name] = tool;
      }
    }
  }

  final AppLogger _logger = AppLogger(null);
  final Map<String, ArchiveTool> _tools = {};

  Iterable<ArchiveTool> get tools => _tools.values;

  /// The `tools` array for a chat request.
  List<Map<String, Object?>> definitions() =>
      [for (final tool in _tools.values) tool.toOpenAi()];

  Future<ToolResult> call(String name, String argumentsJson) async {
    final tool = _tools[name];
    if (tool == null) {
      return ToolResult.error(
        'Unknown tool "$name". Available: ${_tools.keys.join(', ')}.',
      );
    }

    final Object? decoded;
    try {
      decoded = argumentsJson.trim().isEmpty
          ? <String, Object?>{}
          : jsonDecode(argumentsJson);
    } on FormatException catch (e) {
      return ToolResult.error('Arguments for $name are not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      return ToolResult.error('Arguments for $name must be a JSON object.');
    }

    final problems = ToolArgumentValidator.validate(decoded, tool.parameters);
    if (problems.isNotEmpty) {
      return ToolResult.error('Invalid arguments for $name: ${problems.join('; ')}');
    }

    try {
      final result = await tool.run(decoded);
      final size = result.toJson().length;
      if (size > ToolBudgets.maxResultChars) {
        _logger.w('ToolRegistry: $name returned $size chars, over budget');
        return ToolResult.error(
          'The result was too large ($size characters). Ask for fewer items.',
        );
      }
      return result;
    } catch (e, stackTrace) {
      _logger.e('ToolRegistry: $name failed: $e', error: e, stackTrace: stackTrace);
      return ToolResult.error('$name failed: $e');
    }
  }
}

/// Checks arguments against the JSON Schema subset our tools use: object
/// properties, `required`, `additionalProperties: false`, the types string,
/// integer, number, boolean and array, `enum`, and `minimum` / `maximum`.
///
/// Hand-written rather than a dependency because that subset is all the tools
/// declare, and an unsupported keyword failing loudly in a test beats one a
/// library silently ignores.
class ToolArgumentValidator {
  static const _supported = {
    'type', 'properties', 'required', 'additionalProperties', 'items',
    'enum', 'minimum', 'maximum', 'description',
  };

  /// Throws [ArgumentError] if [schema] uses anything [validate] can't check.
  static void checkSchema(String path, Map<String, Object?> schema) {
    final unsupported = schema.keys.where((k) => !_supported.contains(k));
    if (unsupported.isNotEmpty) {
      throw ArgumentError('Unsupported schema keyword(s) at $path: $unsupported');
    }
    const types = {'string', 'integer', 'number', 'boolean', 'array', 'object', null};
    if (!types.contains(schema['type'])) {
      throw ArgumentError('Unsupported type "${schema['type']}" at $path');
    }
    final properties = (schema['properties'] as Map?)?.cast<String, Object?>();
    properties?.forEach((key, value) {
      checkSchema('$path.$key', (value as Map).cast<String, Object?>());
    });
    if (schema['items'] is Map) {
      checkSchema('$path[]', (schema['items'] as Map).cast<String, Object?>());
    }
  }

  /// Every problem found, or an empty list when [args] match.
  static List<String> validate(
    Map<String, Object?> args,
    Map<String, Object?> schema,
  ) {
    final problems = <String>[];
    final properties =
        (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
    final required = (schema['required'] as List?)?.cast<String>() ?? const [];

    for (final key in required) {
      if (args[key] == null) problems.add('"$key" is required');
    }
    for (final entry in args.entries) {
      final propSchema = properties[entry.key];
      if (propSchema == null) {
        if (schema['additionalProperties'] == false) {
          problems.add('unknown argument "${entry.key}"');
        }
        continue;
      }
      if (entry.value == null) continue;
      _check(
        entry.key,
        entry.value,
        (propSchema as Map).cast<String, Object?>(),
        problems,
      );
    }
    return problems;
  }

  static void _check(
    String path,
    Object? value,
    Map<String, Object?> schema,
    List<String> problems,
  ) {
    final type = schema['type'];
    final ok = switch (type) {
      'string' => value is String,
      'integer' => value is int || (value is double && value == value.roundToDouble()),
      'number' => value is num,
      'boolean' => value is bool,
      'array' => value is List,
      'object' => value is Map,
      _ => true, // checkSchema rejected anything else at startup
    };
    if (!ok) {
      problems.add('"$path" must be $type');
      return;
    }
    final allowed = schema['enum'] as List?;
    if (allowed != null && !allowed.contains(value)) {
      problems.add('"$path" must be one of ${allowed.join(', ')}');
    }
    if (value is num) {
      final min = schema['minimum'] as num?;
      final max = schema['maximum'] as num?;
      if (min != null && value < min) problems.add('"$path" must be >= $min');
      if (max != null && value > max) problems.add('"$path" must be <= $max');
    }
    if (value is List && schema['items'] is Map) {
      final itemSchema = (schema['items'] as Map).cast<String, Object?>();
      for (var i = 0; i < value.length; i++) {
        _check('$path[$i]', value[i], itemSchema, problems);
      }
    }
  }
}
