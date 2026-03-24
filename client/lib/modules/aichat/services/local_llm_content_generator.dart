import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';
import 'package:http/http.dart' as http;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/main.dart';

class LocalLlmContentGenerator implements ContentGenerator {
  final String systemInstruction;
  final AppLogger logger = AppLogger(null);

  LocalLlmContentGenerator({required this.systemInstruction});

  final _a2uiMessageController = StreamController<A2uiMessage>.broadcast();
  final _textResponseController = StreamController<String>.broadcast();
  final _errorController = StreamController<ContentGeneratorError>.broadcast();
  final _isProcessing = ValueNotifier<bool>(false);
  String? model; // Selected model ID
  // We still keep local history for UI purposes if needed, but don't send it to server
  final List<ChatMessage> _localHistory = [];
  // Generate a unique session ID for this instance
  final String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

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
      String? llmServiceUrl = MainApp.llmServiceUrl.valueOrNull;
      if (llmServiceUrl == null || llmServiceUrl.isEmpty) {
        throw Exception('LLM Service is not running.');
      }

      // We now rely on server-side history. Only send the new user message.
      String prompt = '';

      // Add current message
      if (message is UserMessage) {
        prompt = message.text;
        _localHistory.add(message);
      }

      final response = await http.post(
        Uri.parse("$llmServiceUrl/chat"),
        headers: <String, String>{
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: jsonEncode(<String, dynamic>{
          "prompt": prompt,
          "system_instruction": systemInstruction,
          "use_genui": true,
          "session_id": _sessionId, // Send session ID
          "model": model, // Send model ID
        }),
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final aiResponse = responseData['ai_response'];

        logger.d('Received aiResponse type: ${aiResponse.runtimeType}');
        // logger.d('Received aiResponse: $aiResponse');

        // Add response to local history
        _localHistory.add(InternalMessage(aiResponse.toString()));

        if (aiResponse.trim().startsWith('[') &&
            aiResponse.trim().endsWith(']')) {
          // GenUI message array
          try {
            final List<dynamic> messagesJson = jsonDecode(aiResponse);
            logger.d('Parsed ${messagesJson.length} GenUI messages');

            // Emit each message to the stream
            for (final messageJson in messagesJson) {
              final message = A2uiMessage.fromJson(messageJson);
              logger.d('Emitting message: ${message.runtimeType}');
              _a2uiMessageController.add(message);
            }
          } catch (e) {
            logger.e('Failed to parse GenUI message array: $e');
            _textResponseController.add(aiResponse);
          }
        } else if (aiResponse.trim().startsWith('{') &&
            aiResponse.trim().endsWith('}')) {
          // Single GenUI message (legacy format)
          try {
            final jsonResponse = jsonDecode(aiResponse);
            logger.d('Parsed JSON successfully: $jsonResponse');
            final message = A2uiMessage.fromJson(jsonResponse);
            logger.d('Created A2uiMessage, emitting to stream...');
            _a2uiMessageController.add(message);
            logger.d('A2uiMessage emitted to stream');
          } catch (e) {
            logger.e('Failed to parse as GenUI JSON: $e');
            _textResponseController.add(aiResponse);
          }
        } else {
          // Plain text response
          logger.d('Emitting plain text response');
          _textResponseController.add(aiResponse);
        }
      } else {
        _errorController.add(
          ContentGeneratorError(
            'Failed to get response: ${response.statusCode}',
            StackTrace.current,
          ),
        );
      }
    } catch (e, stackTrace) {
      _errorController.add(ContentGeneratorError(e.toString(), stackTrace));
    } finally {
      _isProcessing.value = false;
    }
  }
}
