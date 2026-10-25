import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/aichat/services/agent_loop.dart';
import 'package:mydatastudio/modules/aichat/services/tools/tool_registry.dart';

class LocalLlmContentGenerator implements ContentGenerator {
  final String systemInstruction;
  final AppLogger logger = AppLogger(null);

  LocalLlmContentGenerator({required this.systemInstruction});

  final _a2uiMessageController = StreamController<A2uiMessage>.broadcast();
  final _textResponseController = StreamController<String>.broadcast();
  final _errorController = StreamController<ContentGeneratorError>.broadcast();
  final _streamingChunkController = StreamController<String>.broadcast();
  final _toolActivityController = StreamController<ToolActivity>.broadcast();
  final _toolTurnController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _isProcessing = ValueNotifier<bool>(false);

  String? model;

  /// Absolute path to the .gguf file for the selected model.
  /// Set when a downloaded local model is selected so the server can load it
  /// directly without a registry lookup.
  String? modelPath;

  /// Absolute path to the mmproj .gguf file for multimodal vision models.
  String? mmprojPath;

  /// API key for cloud models (e.g., Gemini). Sent as `api_key` in the request body.
  String? apiKey;

  /// Image bytes to include in the next request. Cleared after each send.
  List<Uint8List> pendingAttachments = [];

  /// The model alias the server reported in its last response.
  /// Reflects what was actually loaded, not what the client requested.
  String? lastResponseModel;

  /// Token usage from the last completed response (prompt, completion, total).
  /// Null for local models or when the server does not return usage data.
  Map<String, int>? lastUsage;

  /// When set, overrides [systemInstruction] for the next request only.
  /// Cleared automatically after each send.
  String? skillSystemPrompt;

  /// Tools offered to the model on the next request, or null for none.
  /// The page sets this per send: only local models, only when the
  /// conversation has archive search on, never for a skill.
  ToolRegistry? toolRegistry;

  // Client-side conversation history in OpenAI format (content may be string or list).
  final List<Map<String, dynamic>> _messages = [];

  // Active streaming state — used by cancelStream().
  http.Client? _activeClient;
  bool _cancelled = false;

  // Completion id of the active stream (from the SSE chunks). Sent to
  // /v1/chat/stop so the server cancels only this generation.
  String? _activeCompletionId;

  @override
  Stream<A2uiMessage> get a2uiMessageStream => _a2uiMessageController.stream;

  @override
  Stream<ContentGeneratorError> get errorStream => _errorController.stream;

  @override
  ValueListenable<bool> get isProcessing => _isProcessing;

  @override
  Stream<String> get textResponseStream => _textResponseController.stream;

  /// Emits individual token chunks as they stream from the server.
  Stream<String> get streamingChunkStream => _streamingChunkController.stream;

  /// A tool starting or finishing during the current turn.
  Stream<ToolActivity> get toolActivityStream => _toolActivityController.stream;

  /// The tool-call and tool-result messages a turn produced, emitted once
  /// before its final answer so the page can persist them in order.
  Stream<List<Map<String, dynamic>>> get toolTurnStream =>
      _toolTurnController.stream;

  /// Cancel the active stream: closes the HTTP connection and signals the
  /// server to stop. Whatever was already received is committed.
  Future<void> cancelStream() async {
    if (!_isProcessing.value) return;
    _cancelled = true;
    _activeClient?.close();
    try {
      final url = MainApp.llmServiceUrl.valueOrNull;
      if (url != null) {
        final headers = aiServerAuthHeaders(
          MainApp.llmServiceToken.valueOrNull,
        );
        final completionId = _activeCompletionId;
        await http
            .post(
              Uri.parse('$url/v1/chat/stop'),
              headers:
                  completionId != null
                      ? {...headers, 'Content-Type': 'application/json'}
                      : headers,
              body:
                  completionId != null
                      ? jsonEncode({'id': completionId})
                      : null,
            )
            .timeout(const Duration(seconds: 2));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    // Close any in-flight streaming connection so it doesn't leak past disposal.
    _cancelled = true;
    _activeClient?.close();
    _activeClient = null;
    _a2uiMessageController.close();
    _textResponseController.close();
    _errorController.close();
    _streamingChunkController.close();
    _toolActivityController.close();
    _toolTurnController.close();
    _isProcessing.dispose();
  }

  @override
  Future<void> sendRequest(
    ChatMessage message, {
    A2UiClientCapabilities? clientCapabilities,
    Iterable<ChatMessage>? history,
  }) async {
    // Guard against re-entrancy: a second send while one is already streaming
    // would overwrite _activeClient and interleave writes into _messages.
    if (_isProcessing.value) return;
    _isProcessing.value = true;
    _cancelled = false;
    _activeCompletionId = null;
    try {
      final String? llmServiceUrl = MainApp.llmServiceUrl.valueOrNull;
      if (llmServiceUrl == null || llmServiceUrl.isEmpty) {
        throw Exception('LLM Service is not running.');
      }

      if (message is UserMessage) {
        final attachments = List<Uint8List>.from(pendingAttachments);
        pendingAttachments = [];
        logger.d(
          '[ATTACH] sendRequest: ${attachments.length} attachment(s), text="${message.text}"',
        );

        if (attachments.isNotEmpty) {
          // Multimodal: build OpenAI content array with images first, then text
          final content = <Map<String, dynamic>>[
            for (final bytes in attachments)
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,${base64Encode(bytes)}',
                },
              },
            if (message.text.isNotEmpty) {'type': 'text', 'text': message.text},
          ];
          _messages.add({'role': 'user', 'content': content});
        } else {
          _messages.add({'role': 'user', 'content': message.text});
        }
      }

      final activeSystemPrompt = skillSystemPrompt ?? systemInstruction;
      skillSystemPrompt = null; // consume — applies to this request only
      final registry = toolRegistry;
      final systemPrompt =
          registry == null
              ? activeSystemPrompt
              : '$activeSystemPrompt\n\n${archiveToolsPrompt(DateTime.now())}';
      final List<Map<String, dynamic>> requestMessages = [
        if (systemPrompt.isNotEmpty) {'role': 'system', 'content': systemPrompt},
        ..._messages,
      ];

      lastResponseModel = null;
      lastUsage = null;

      if (registry == null) {
        final turn = await _streamTurn(llmServiceUrl, requestMessages, null);
        if (turn != null && turn.content.isNotEmpty) {
          _messages.add({'role': 'assistant', 'content': turn.content});
          _textResponseController.add(turn.content);
        }
        return;
      }

      final result = await AgentLoop(
        registry: registry,
        transport: (messages, tools) => _streamTurn(llmServiceUrl, messages, tools),
        onActivity: _toolActivityController.add,
        isCancelled: () => _cancelled,
      ).run(requestMessages);

      // Everything the loop added goes into the history, so a follow-up
      // ("open the second one") can see the results it refers to.
      _messages.addAll(result.added);
      final steps = [
        for (final m in result.added)
          if (m['role'] == 'tool' || m['tool_calls'] != null) m,
      ];
      if (steps.isNotEmpty) _toolTurnController.add(steps);
      final text = result.finalText;
      if (text != null && text.isNotEmpty) _textResponseController.add(text);
    } catch (e, stackTrace) {
      if (!_cancelled) {
        _errorController.add(ContentGeneratorError(e.toString(), stackTrace));
      }
    } finally {
      _cancelled = false;
      _isProcessing.value = false;
    }
  }

  /// Sends one completion request and streams its text to the UI.
  ///
  /// Returns the reply, including whatever text arrived before a cancel or a
  /// dropped connection (kept, as before tool support), or null when the
  /// request failed outright.
  Future<AssistantTurn?> _streamTurn(
    String llmServiceUrl,
    List<Map<String, dynamic>> messages,
    List<Map<String, Object?>>? tools,
  ) async {
    final request = http.Request(
      'POST',
      Uri.parse('$llmServiceUrl/v1/chat/completions'),
    );
    request.headers['Content-Type'] = 'application/json; charset=UTF-8';
    request.headers.addAll(
      aiServerAuthHeaders(MainApp.llmServiceToken.valueOrNull),
    );
    request.body = jsonEncode({
      'model': model ?? '',
      if (modelPath != null && modelPath!.isNotEmpty) 'model_path': modelPath,
      if (mmprojPath != null && mmprojPath!.isNotEmpty)
        'mmproj_path': mmprojPath,
      if (apiKey != null && apiKey!.isNotEmpty) 'api_key': apiKey,
      'messages': messages,
      if (tools != null) 'tools': tools,
      'stream': true,
    });

    final client = http.Client();
    _activeClient = client;
    _activeCompletionId = null;
    try {
      final streamedResponse = await client.send(request);

      if (streamedResponse.statusCode != 200) {
        final body = await streamedResponse.stream.bytesToString();
        // 409 means the server's single generation slot is taken. The UI
        // already guards this via isProcessing, so reaching it means two
        // senders raced — say so plainly rather than dumping the JSON body.
        _errorController.add(
          ContentGeneratorError(
            streamedResponse.statusCode == 409
                ? 'The model is already generating a response. '
                    'Wait for it to finish, or press stop.'
                : 'Failed to get response: ${streamedResponse.statusCode} — $body',
            StackTrace.current,
          ),
        );
        return null;
      }

      final buffer = StringBuffer();
      // Streamed tool calls arrive as fragments keyed by index.
      final calls = <int, Map<String, dynamic>>{};

      // Wrap the stream loop so that any interruption (cancel or server
      // disconnect) falls through to the commit step below.
      try {
        await for (final line in streamedResponse.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6).trim();
          if (data == '[DONE]') break;
          try {
            final parsed = jsonDecode(data) as Map<String, dynamic>;
            lastResponseModel ??= parsed['model'] as String?;
            _activeCompletionId ??= parsed['id'] as String?;
            final choices = parsed['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final delta =
                  (choices[0] as Map<String, dynamic>)['delta']
                      as Map<String, dynamic>?;
              final content = delta?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                buffer.write(content);
                _streamingChunkController.add(content);
              }
              for (final fragment in (delta?['tool_calls'] as List?) ?? const []) {
                _mergeToolCallFragment(calls, fragment as Map<String, dynamic>);
              }
            }
            // Capture token usage from the final SSE chunk (Gemini / cloud models)
            final usage = parsed['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              lastUsage = {
                'prompt_tokens': (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
                'completion_tokens':
                    (usage['completion_tokens'] as num?)?.toInt() ?? 0,
                'total_tokens': (usage['total_tokens'] as num?)?.toInt() ?? 0,
              };
            }
          } catch (_) {}
        }
      } catch (_) {
        // Stream was interrupted (user cancel or server disconnect).
        // Fall through to commit whatever is in the buffer.
      }

      final ordered = calls.keys.toList()..sort();
      return AssistantTurn(
        content: buffer.toString(),
        toolCalls: [for (final i in ordered) calls[i]!],
      );
    } finally {
      _activeClient = null;
      client.close();
    }
  }

  static void _mergeToolCallFragment(
    Map<int, Map<String, dynamic>> calls,
    Map<String, dynamic> fragment,
  ) {
    final index = (fragment['index'] as num?)?.toInt() ?? calls.length;
    final call = calls.putIfAbsent(
      index,
      () => {
        'id': '',
        'type': 'function',
        'function': <String, dynamic>{'name': '', 'arguments': ''},
      },
    );
    if (fragment['id'] case final String id) call['id'] = id;
    final function = fragment['function'] as Map<String, dynamic>?;
    final target = call['function'] as Map<String, dynamic>;
    if (function?['name'] case final String name) {
      target['name'] = (target['name'] as String) + name;
    }
    if (function?['arguments'] case final String args) {
      target['arguments'] = (target['arguments'] as String) + args;
    }
  }

  void clearHistory() {
    _messages.clear();
    pendingAttachments = [];
  }

  /// Restores message history (OpenAI format) when loading a saved conversation.
  void loadHistory(List<Map<String, dynamic>> messages) {
    _messages.clear();
    _messages.addAll(messages);
  }
}
