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
  final _streamingChunkController = StreamController<String>.broadcast();
  final _isProcessing = ValueNotifier<bool>(false);

  String? model;

  /// Image bytes to include in the next request. Cleared after each send.
  List<Uint8List> pendingAttachments = [];

  // Client-side conversation history in OpenAI format (content may be string or list).
  final List<Map<String, dynamic>> _messages = [];

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

  @override
  void dispose() {
    _a2uiMessageController.close();
    _textResponseController.close();
    _errorController.close();
    _streamingChunkController.close();
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
        final attachments = List<Uint8List>.from(pendingAttachments);
        pendingAttachments = [];
        logger.d('[ATTACH] sendRequest: ${attachments.length} attachment(s), text="${message.text}"');

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

      final List<Map<String, dynamic>> requestMessages = [
        if (systemInstruction.isNotEmpty)
          {'role': 'system', 'content': systemInstruction},
        ..._messages,
      ];

      final request = http.Request(
        'POST',
        Uri.parse('$llmServiceUrl/v1/chat/completions'),
      );
      request.headers['Content-Type'] = 'application/json; charset=UTF-8';
      request.body = jsonEncode({
        'model': model ?? '',
        'messages': requestMessages,
        'stream': true,
      });

      final client = http.Client();
      try {
        final streamedResponse = await client.send(request);

        if (streamedResponse.statusCode != 200) {
          final body = await streamedResponse.stream.bytesToString();
          _errorController.add(ContentGeneratorError(
            'Failed to get response: ${streamedResponse.statusCode} — $body',
            StackTrace.current,
          ));
          return;
        }

        final buffer = StringBuffer();
        await for (final line in streamedResponse.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6).trim();
          if (data == '[DONE]') break;
          try {
            final parsed = jsonDecode(data) as Map<String, dynamic>;
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
            }
          } catch (_) {}
        }

        final fullContent = buffer.toString();
        if (fullContent.isNotEmpty) {
          _messages.add({'role': 'assistant', 'content': fullContent});
          _textResponseController.add(fullContent);
        }
      } finally {
        client.close();
      }
    } catch (e, stackTrace) {
      _errorController.add(ContentGeneratorError(e.toString(), stackTrace));
    } finally {
      _isProcessing.value = false;
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
