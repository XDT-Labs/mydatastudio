import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:genui/genui.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/modules/aichat/services/local_llm_content_generator.dart';
import 'package:mydatastudio/python_manager.dart';
import 'package:file_picker/file_picker.dart';

class AichatPage extends StatefulWidget {
  const AichatPage({super.key});

  @override
  State<AichatPage> createState() => _AichatPage();
}

sealed class ChatItem {}

class TextMessageItem extends ChatItem {
  final String role;
  final String text;
  TextMessageItem({required this.role, required this.text});
}

class GenUiSurfaceItem extends ChatItem {
  final String surfaceId;
  GenUiSurfaceItem({required this.surfaceId});
}

class _AichatPage extends State<AichatPage> {
  AppLogger logger = AppLogger(null);
  bool _isLLMServiceRunning = PythonManager.isLLMServiceRunning.value;
  String _selectedModel = 'Local LLM';
  final List<String> _models = ['Local LLM', 'Gemini'];

  static const Map<String, String> _modelAliases = {
    'Local LLM': 'gemma4:12b',
    'Gemini': 'gemini',
  };

  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  late final LocalLlmContentGenerator _contentGenerator;
  late final A2uiMessageProcessor _a2uiMessageProcessor;
  late final GenUiConversation _genUiConversation;
  final List<ChatItem> _chatItems = [];

  // Accumulates streaming tokens; null when idle.
  String? _streamingText;

  // Files staged for the next message (cleared after send).
  final List<PlatformFile> _pendingFiles = [];

  @override
  void initState() {
    super.initState();

    PythonManager.isLLMServiceRunning.addListener(() {
      if (mounted) {
        setState(() {
          _isLLMServiceRunning = PythonManager.isLLMServiceRunning.value;
        });
      }
    });

    _a2uiMessageProcessor = A2uiMessageProcessor(
      catalogs: [CoreCatalogItems.asCatalog()],
    );

    _contentGenerator = LocalLlmContentGenerator(
      systemInstruction: 'You are a helpful assistant.',
    );

    // Stream individual tokens → accumulate into the in-progress bubble.
    _contentGenerator.streamingChunkStream.listen((chunk) {
      if (mounted) {
        setState(() {
          _streamingText = (_streamingText ?? '') + chunk;
        });
        _scrollToBottom();
      }
    });

    // Full response arrives → finalize into _chatItems, clear streaming state.
    _contentGenerator.textResponseStream.listen((text) {
      if (mounted) {
        setState(() {
          _chatItems.add(TextMessageItem(role: 'assistant', text: text));
          _streamingText = null;
        });
        _scrollToBottom();
      }
    });

    _a2uiMessageProcessor.surfaceUpdates.listen((_) {});

    _genUiConversation = GenUiConversation(
      a2uiMessageProcessor: _a2uiMessageProcessor,
      contentGenerator: _contentGenerator,
      onSurfaceAdded: _onSurfaceAdded,
      onSurfaceUpdated: (event) {
        _addSurfaceId(event.surfaceId);
      },
      onSurfaceDeleted: _onSurfaceDeleted,
      onError: (error) {
        logger.e('GenUiConversation error: ${error.error}');
        if (mounted) setState(() => _streamingText = null);
      },
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _genUiConversation.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _addSurfaceId(String surfaceId) {
    final exists = _chatItems.any(
      (item) => item is GenUiSurfaceItem && item.surfaceId == surfaceId,
    );
    if (!exists) {
      setState(() {
        _chatItems.add(GenUiSurfaceItem(surfaceId: surfaceId));
      });
    }
  }

  void _onSurfaceAdded(SurfaceAdded event) {
    _addSurfaceId(event.surfaceId);
  }

  void _onSurfaceDeleted(SurfaceRemoved update) {
    setState(() {
      _chatItems.removeWhere(
        (item) =>
            item is GenUiSurfaceItem && item.surfaceId == update.surfaceId,
      );
    });
  }

  Future<void> _sendMessage(String message) async {
    if (message.trim().isEmpty && _pendingFiles.isEmpty) return;

    if (!_isLLMServiceRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('LLM Service is not running.')),
      );
      return;
    }

    // Read attachment bytes before clearing the list.
    if (_pendingFiles.isNotEmpty) {
      logger.d('[ATTACH] Reading ${_pendingFiles.length} file(s): ${_pendingFiles.map((f) => f.name).toList()}');
      final List<Uint8List> bytes = await Future.wait(
        _pendingFiles
            .where((f) => f.path != null)
            .map((f) => File(f.path!).readAsBytes()),
      );
      logger.d('[ATTACH] Read ${bytes.length} file(s)');
      _contentGenerator.pendingAttachments = bytes;
    }

    setState(() {
      _chatItems.add(TextMessageItem(role: 'user', text: message));
      _pendingFiles.clear();
    });

    final alias = _modelAliases[_selectedModel] ?? _selectedModel;
    _contentGenerator.model = alias;

    _genUiConversation.sendRequest(UserMessage.text(message));
    _textController.clear();
    _scrollToBottom();
  }

  Widget _buildUserBubble(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          decoration: BoxDecoration(
            color: Colors.blueAccent.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: Text(text, style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }

  Widget _buildAssistantBubble(String text, {bool streaming = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: MarkdownBody(
            data: streaming ? '$text▋' : text,
            styleSheet: MarkdownStyleSheet(
              p: const TextStyle(color: Colors.black87, fontSize: 15),
              code: TextStyle(
                backgroundColor: Colors.grey.shade300,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
              codeblockDecoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLLMServiceRunning) {
      return const Center(
        child: Text("LLM Service is not running or is still starting up."),
      );
    }

    final itemCount = _chatItems.length + (_streamingText != null ? 1 : 0);

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text("AI Chat"),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(height: 1.0, color: Colors.grey.shade300),
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add, color: Colors.black),
            tooltip: 'New Session',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('todo: new session')),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.only(
                bottom: 20,
                left: 16,
                right: 16,
                top: 16,
              ),
              itemCount: itemCount,
              itemBuilder: (context, index) {
                // In-progress streaming bubble at the end of the list
                if (index == _chatItems.length && _streamingText != null) {
                  return _buildAssistantBubble(
                    _streamingText!,
                    streaming: true,
                  );
                }

                final item = _chatItems[index];

                if (item is TextMessageItem) {
                  return item.role == 'user'
                      ? _buildUserBubble(item.text)
                      : _buildAssistantBubble(item.text);
                }

                if (item is GenUiSurfaceItem) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: GenUiSurface(
                      host: _genUiConversation.host,
                      surfaceId: item.surfaceId,
                    ),
                  );
                }

                return const SizedBox.shrink();
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFFF2F2F7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE5E5EA), width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _textController,
                    onSubmitted: (text) => _sendMessage(text),
                    keyboardType: TextInputType.multiline,
                    minLines: 1,
                    maxLines: 10,
                    style: const TextStyle(fontSize: 15, color: Colors.black87),
                    decoration: const InputDecoration(
                      hintText: "Ask anything, @ to mention, / for workflows",
                      hintStyle: TextStyle(
                        color: Color(0xFFAEB1B7),
                        fontSize: 15,
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12.0,
                        vertical: 12.0,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                  if (_pendingFiles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 4),
                      child: Wrap(
                        spacing: 6,
                        children: _pendingFiles.map((f) {
                          return Chip(
                            label: Text(f.name, style: const TextStyle(fontSize: 12)),
                            deleteIcon: const Icon(Icons.close, size: 14),
                            onDeleted: () => setState(() => _pendingFiles.remove(f)),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          );
                        }).toList(),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 4,
                      right: 8,
                      bottom: 4,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(
                            Icons.add,
                            color: Color(0xFF999999),
                            size: 20,
                          ),
                          onPressed: () async {
                            FilePickerResult? result = await FilePicker.platform
                                .pickFiles(allowMultiple: true);
                            if (result != null) {
                              setState(() => _pendingFiles.addAll(result.files));
                            }
                          },
                        ),
                        const SizedBox(width: 12),
                        Theme(
                          data: Theme.of(context).copyWith(
                            hoverColor: Colors.transparent,
                            splashColor: Colors.transparent,
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedModel,
                              icon: const Padding(
                                padding: EdgeInsets.only(left: 4.0),
                                child: Icon(
                                  Icons.keyboard_arrow_up,
                                  size: 16,
                                  color: Color(0xFF8E8E93),
                                ),
                              ),
                              elevation: 2,
                              onChanged: (String? newValue) {
                                if (newValue != null) {
                                  setState(() {
                                    _selectedModel = newValue;
                                  });
                                }
                              },
                              items: _models.map<DropdownMenuItem<String>>(
                                (String value) {
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(
                                      value,
                                      style: const TextStyle(
                                        color: Color(0xFF8E8E93),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w400,
                                      ),
                                    ),
                                  );
                                },
                              ).toList(),
                            ),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _streamingText != null
                                  ? const Color(0xFF007AFF)
                                  : const Color(0xFFD1D1D6),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              _streamingText != null
                                  ? Icons.stop_rounded
                                  : Icons.arrow_forward_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                          onPressed: () => _sendMessage(_textController.text),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
