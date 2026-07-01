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

  /// Absolute path to the .gguf file for the selected model.
  /// Set when a downloaded local model is selected so the server can load it
  /// directly without a registry lookup.
  String? modelPath;

  /// Absolute path to the mmproj .gguf file for multimodal vision models.
  String? mmprojPath;

  /// Image bytes to include in the next request. Cleared after each send.
  List<Uint8List> pendingAttachments = [];

  /// The model alias the server reported in its last response.
  /// Reflects what was actually loaded, not what the client requested.
  String? lastResponseModel;

  // Client-side conversation history in OpenAI format (content may be string or list).
  final List<Map<String, dynamic>> _messages = [];

  // Active streaming state — used by cancelStream().
  http.Client? _activeClient;
  bool _cancelled = false;

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

  /// Cancel the active stream: closes the HTTP connection and signals the
  /// server to stop. Whatever was already received is committed.
  Future<void> cancelStream() async {
    if (!_isProcessing.value) return;
    _cancelled = true;
    _activeClient?.close();
    try {
      final url = MainApp.llmServiceUrl.valueOrNull;
      if (url != null) {
        await http
            .post(Uri.parse('$url/v1/chat/stop'))
            .timeout(const Duration(seconds: 2));
      }
    } catch (_) {}
  }

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
    _cancelled = false;
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
        if (modelPath != null && modelPath!.isNotEmpty) 'model_path': modelPath,
        if (mmprojPath != null && mmprojPath!.isNotEmpty) 'mmproj_path': mmprojPath,
        'messages': requestMessages,
        'stream': true,
      });

      lastResponseModel = null;
      final client = http.Client();
      _activeClient = client;
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
        } catch (_) {
          // Stream was interrupted (user cancel or server disconnect).
          // Fall through to commit whatever is in the buffer.
        }

        final fullContent = buffer.toString();
        if (fullContent.isNotEmpty) {
          _messages.add({'role': 'assistant', 'content': fullContent});
          _textResponseController.add(fullContent);
        }
      } finally {
        _activeClient = null;
        client.close();
      }
    } catch (e, stackTrace) {
      if (!_cancelled) {
        _errorController.add(ContentGeneratorError(e.toString(), stackTrace));
      }
    } finally {
      _cancelled = false;
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
