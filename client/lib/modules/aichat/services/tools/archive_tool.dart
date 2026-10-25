import 'dart:convert';

/// One thing the chat model can do with the user's archive.
///
/// Defined once and exposed to the model as an OpenAI-style function
/// (docs/adr/0001-llm-tool-registry.md). Tools are read-only for now; the flag
/// is here so a future write tool has to say so explicitly.
abstract class ArchiveTool {
  String get name;

  /// What the model reads to decide when to call this. Write it for the
  /// model: say what it returns and when *not* to use it.
  String get description;

  /// JSON Schema (the subset [ToolArgumentValidator] checks) for the arguments.
  Map<String, Object?> get parameters;

  bool get isReadOnly => true;

  /// Runs with arguments that already passed [parameters] validation.
  Future<ToolResult> run(Map<String, Object?> args);

  Map<String, Object?> toOpenAi() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// A module's contribution to the registry.
abstract class ToolProvider {
  List<ArchiveTool> get tools;
}

/// What a tool hands back to the model, as JSON.
class ToolResult {
  ToolResult.ok(this.data) : isError = false;

  ToolResult.error(String message) : data = {'error': message}, isError = true;

  final Map<String, Object?> data;
  final bool isError;

  String toJson() => jsonEncode(data);
}
