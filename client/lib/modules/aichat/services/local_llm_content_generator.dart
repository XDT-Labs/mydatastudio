import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/main.dart';

class LocalLlmContentGenerator implements ContentGenerator {
  final String systemInstruction;
  final AppLogger logger = AppLogger(null);

  LocalLlmContentGenerator({required this.systemInstruction});

  final _a2uiMessageController = StreamController<A2uiMessage>.broadcast();
  final _textResponseController = StreamController<String>.broadcast();
  final _errorController = StreamController<ContentGeneratorError>.broadcast();
  final _isProcessing = ValueNotifier<bool>(false);

  String? model;

  // Client-side conversation history in OpenAI format. Each request sends
  // the full history so the server remains stateless.
  final List<Map<String, String>> _messages = [];

  @override
  Stream<A2uiMessage> get a2uiMessageStream => _a2uiMessageController.stream;

  @override
  Stream<ContentGeneratorError> get errorStream => _errorController.stream;

  @override
  ValueListenable<bool> get isProcessing => _isProcessing;

  @override
  Stream<String> get textResponseStream => _textResponseController.stream;

  @override
  void dispose() {
    _a2uiMessageController.close();
    _textResponseController.close();
    _errorController.close();
    _isProcessing.dispose();
  }

  @override
  Future<void> sendRequest(
    ChatMessage message, {
    A2UiClientCapabilities? clientCapabilities,
    Iterable<ChatMessage>? history,
  }) async {
    _isProcessing.value = true;
    try {
      final String? llmServiceUrl = MainApp.llmServiceUrl.valueOrNull;
      if (llmServiceUrl == null || llmServiceUrl.isEmpty) {
        throw Exception('LLM Service is not running.');
      }

      if (message is UserMessage) {
        _messages.add({'role': 'user', 'content': message.text});
      }

      // Build the full message list: system prompt (if any) + conversation history
      final List<Map<String, String>> requestMessages = [
        if (systemInstruction.isNotEmpty)
          {'role': 'system', 'content': systemInstruction},
        ..._messages,
      ];

      final response = await http.post(
        Uri.parse('$llmServiceUrl/v1/chat/completions'),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: jsonEncode({
          'model': model ?? '',
          'messages': requestMessages,
        }),
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final String content =
            responseData['choices'][0]['message']['content'] as String;

        _messages.add({'role': 'assistant', 'content': content});
        _textResponseController.add(content);
      } else {
        _errorController.add(ContentGeneratorError(
          'Failed to get response: ${response.statusCode} — ${response.body}',
          StackTrace.current,
        ));
      }
    } catch (e, stackTrace) {
      _errorController.add(ContentGeneratorError(e.toString(), stackTrace));
    } finally {
      _isProcessing.value = false;
    }
  }

  /// Clear local conversation history (e.g. when the user starts a new chat).
  void clearHistory() => _messages.clear();
}
