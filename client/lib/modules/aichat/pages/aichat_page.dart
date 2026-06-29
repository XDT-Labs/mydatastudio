import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:genui/genui.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/modules/aichat/services/local_llm_content_generator.dart';
import 'package:mydatastudio/python_manager.dart';
import 'package:file_picker/file_picker.dart';

// Dark theme colors
const _bgColor = Color(0xFF000000);
const _inputBgColor = Color(0xFF1C1C1E);
const _inputBorderColor = Color(0xFF3A3A3C);
const _userBubbleColor = Color(0xFF2C2C2E);
const _hintColor = Color(0xFF636366);
const _mutedColor = Color(0xFF8E8E93);
const _sendEnabledBg = Color(0xFFFFFFFF);
const _sendDisabledBg = Color(0xFF3A3A3C);

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
  final _focusNode = FocusNode();

  late final LocalLlmContentGenerator _contentGenerator;
  late final A2uiMessageProcessor _a2uiMessageProcessor;
  late final GenUiConversation _genUiConversation;
  final List<ChatItem> _chatItems = [];

  // Accumulates streaming tokens; null when idle.
  String? _streamingText;

  // Files staged for the next message (cleared after send).
  final List<PlatformFile> _pendingFiles = [];

  bool get _canSend =>
      _textController.text.trim().isNotEmpty || _pendingFiles.isNotEmpty;

  @override
  void initState() {
    super.initState();

    _textController.addListener(() => setState(() {}));

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

    _contentGenerator.streamingChunkStream.listen((chunk) {
      if (mounted) {
        setState(() {
          _streamingText = (_streamingText ?? '') + chunk;
        });
        _scrollToBottom();
      }
    });

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
    _focusNode.dispose();
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
    _focusNode.requestFocus();
    _scrollToBottom();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _sendMessage(_textController.text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          decoration: BoxDecoration(
            color: _userBubbleColor,
            borderRadius: BorderRadius.circular(18.0),
          ),
          child: Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantBubble(String text, {bool streaming = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          child: MarkdownBody(
            data: streaming ? '$text▋' : text,
            styleSheet: MarkdownStyleSheet(
              p: const TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
              code: TextStyle(
                backgroundColor: const Color(0xFF2C2C2E),
                color: const Color(0xFFE5E5EA),
                fontFamily: 'monospace',
                fontSize: 13,
              ),
              codeblockDecoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _inputBorderColor),
              ),
              blockquoteDecoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                border: Border(left: BorderSide(color: _mutedColor, width: 3)),
              ),
              h1: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              h2: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              h3: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              listBullet: const TextStyle(color: Colors.white),
              strong: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              em: const TextStyle(color: Color(0xFFE5E5EA), fontStyle: FontStyle.italic),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLLMServiceRunning) {
      return const ColoredBox(
        color: _bgColor,
        child: Center(
          child: Text(
            "LLM Service is not running or is still starting up.",
            style: TextStyle(color: _mutedColor),
          ),
        ),
      );
    }

    final itemCount = _chatItems.length + (_streamingText != null ? 1 : 0);

    return Theme(
      data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: _bgColor,
        appBarTheme: const AppBarTheme(
          backgroundColor: _bgColor,
          foregroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      child: Scaffold(
        backgroundColor: _bgColor,
        appBar: AppBar(
          backgroundColor: _bgColor,
          centerTitle: false,
          title: const Text(
            "AI Chat",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1.0),
            child: Container(height: 1.0, color: _inputBorderColor),
          ),
          actions: <Widget>[
            IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
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
                  left: 24,
                  right: 24,
                  top: 24,
                ),
                itemCount: itemCount,
                itemBuilder: (context, index) {
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
              color: _bgColor,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Container(
                decoration: BoxDecoration(
                  color: _inputBgColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _inputBorderColor, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Focus(
                      focusNode: _focusNode,
                      onKeyEvent: _handleKeyEvent,
                      child: TextField(
                        controller: _textController,
                        keyboardType: TextInputType.multiline,
                        minLines: 1,
                        maxLines: 10,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Colors.white,
                        ),
                        decoration: const InputDecoration(
                          hintText: "Send a message... (@ to mention, / for commands)",
                          hintStyle: TextStyle(
                            color: _hintColor,
                            fontSize: 15,
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14.0,
                            vertical: 14.0,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                    if (_pendingFiles.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, top: 4),
                        child: Wrap(
                          spacing: 6,
                          children: _pendingFiles.map((f) {
                            return Chip(
                              label: Text(
                                f.name,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white,
                                ),
                              ),
                              backgroundColor: const Color(0xFF3A3A3C),
                              deleteIcon: const Icon(
                                Icons.close,
                                size: 14,
                                color: _mutedColor,
                              ),
                              onDeleted: () =>
                                  setState(() => _pendingFiles.remove(f)),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                            );
                          }).toList(),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 8, 8),
                      child: Row(
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(
                              Icons.add,
                              color: _mutedColor,
                              size: 20,
                            ),
                            onPressed: () async {
                              FilePickerResult? result =
                                  await FilePicker.platform.pickFiles(
                                allowMultiple: true,
                              );
                              if (result != null) {
                                setState(
                                    () => _pendingFiles.addAll(result.files));
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
                                dropdownColor: const Color(0xFF2C2C2E),
                                icon: const Padding(
                                  padding: EdgeInsets.only(left: 4.0),
                                  child: Icon(
                                    Icons.keyboard_arrow_up,
                                    size: 16,
                                    color: _mutedColor,
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
                                          color: _mutedColor,
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
                          GestureDetector(
                            onTap: _canSend && _streamingText == null
                                ? () => _sendMessage(_textController.text)
                                : null,
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _canSend && _streamingText == null
                                    ? _sendEnabledBg
                                    : _sendDisabledBg,
                              ),
                              child: Icon(
                                Icons.arrow_upward_rounded,
                                color: _canSend && _streamingText == null
                                    ? Colors.black
                                    : _mutedColor,
                                size: 18,
                              ),
                            ),
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
      ),
    );
  }
}
