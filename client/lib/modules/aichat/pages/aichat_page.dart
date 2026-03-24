import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/modules/aichat/services/local_llm_content_generator.dart';
import 'package:mydatatools/python_manager.dart';

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
  String _selectedModel = 'Gemini 3 Flash';
  final List<String> _models = ['Gemini 3 Flash', 'Local LLM', 'ChatGPT', 'Grok'];
  final _textController = TextEditingController();


  late final A2uiMessageProcessor _a2uiMessageProcessor;
  late final GenUiConversation _genUiConversation;
  final List<ChatItem> _chatItems = [];

  @override
  void initState() {
    super.initState();


    // listen for changes
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

    final contentGenerator = LocalLlmContentGenerator(
      systemInstruction: 'You are a helpful assistant.',
    );

    // Debug: Listen to a2uiMessageStream to see if messages are flowing
    // This must be done BEFORE creating GenUiConversation
    contentGenerator.a2uiMessageStream.listen(
      (message) {
        //logger.d('DEBUG: a2uiMessageStream received message: $message');
      },
      onError: (error) {
        //logger.e('DEBUG: a2uiMessageStream error: $error');
      },
      onDone: () {
        //logger.d('DEBUG: a2uiMessageStream done');
      },
    );

    // Listen to text responses from the generator for non-UI messages
    contentGenerator.textResponseStream.listen((text) {
      logger.d('DEBUG: textResponseStream received: $text');
      if (mounted) {
        setState(() {
          _chatItems.add(TextMessageItem(role: 'assistant', text: text));
        });
      }
    });

    // Debug: Listen to surfaceUpdates directly
    _a2uiMessageProcessor.surfaceUpdates.listen((event) {
      //logger.d('DEBUG: A2uiMessageProcessor emitted event: $event');
    });

    // logger.d('Creating GenUiConversation...');
    _genUiConversation = GenUiConversation(
      a2uiMessageProcessor: _a2uiMessageProcessor,
      contentGenerator: contentGenerator,
      onSurfaceAdded: _onSurfaceAdded,
      onSurfaceUpdated: (event) {
        //logger.d('SurfaceUpdated event: ${event.surfaceId}');
        _addSurfaceId(event.surfaceId);
      },
      onSurfaceDeleted: _onSurfaceDeleted,
      onError: (error) {
        logger.e('GenUiConversation error: $error');
      },
    );
    // logger.d('GenUiConversation created');
  }

  @override
  void dispose() {
    _textController.dispose();
    _genUiConversation.dispose();
    super.dispose();
  }

  void _addSurfaceId(String surfaceId) {
    // Check if surface is already in the list
    final exists = _chatItems.any(
      (item) => item is GenUiSurfaceItem && item.surfaceId == surfaceId,
    );

    if (!exists) {
      setState(() {
        _chatItems.add(GenUiSurfaceItem(surfaceId: surfaceId));
      });
      logger.d('Surface added to list: $surfaceId');
      logger.d('Total items: ${_chatItems.length}');
    }
  }

  void _onSurfaceAdded(SurfaceAdded event) {
    logger.d('SurfaceAdded event: ${event.surfaceId}');
    _addSurfaceId(event.surfaceId);
  }

  void _onSurfaceDeleted(SurfaceRemoved update) {
    logger.d('Surface deleted: ${update.surfaceId}');
    setState(() {
      _chatItems.removeWhere(
        (item) =>
            item is GenUiSurfaceItem && item.surfaceId == update.surfaceId,
      );
    });
  }



  void _sendMessage(String message) {
    if (message.trim().isEmpty) {
      return;
    }

    if (!_isLLMServiceRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('LLM Service is not running.')),
      );
      return;
    }

    // Add user message to chat items
    setState(() {
      _chatItems.add(TextMessageItem(role: 'user', text: message));
    });

    if (_genUiConversation.contentGenerator is LocalLlmContentGenerator) {
      (_genUiConversation.contentGenerator as LocalLlmContentGenerator).model = _selectedModel;
    }
    _genUiConversation.sendRequest(UserMessage.text(message));
    _textController.clear();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLLMServiceRunning) {
      return const Center(
        child: Text("LLM Service is not running or is still starting up."),
      );
    }

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
              padding: const EdgeInsets.only(
                bottom: 20,
                left: 16,
                right: 16,
                top: 16,
              ),
              itemCount: _chatItems.length,
              itemBuilder: (context, index) {
                final item = _chatItems[index];

                if (item is TextMessageItem) {
                  final isUser = item.role == 'user';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Align(
                      alignment:
                          isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.75,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12.0,
                          vertical: 8.0,
                        ),
                        decoration: BoxDecoration(
                          color:
                              isUser
                                  ? Colors.blueAccent.withValues(alpha: 0.9)
                                  : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12.0),
                        ),
                        child: Text(
                          item.text,
                          style: TextStyle(
                            color: isUser ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                    ),
                  );
                } else if (item is GenUiSurfaceItem) {
                  // logger.d('Rendering GenUiSurface for surface: ${item.surfaceId}',);
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
                    onSubmitted: _sendMessage,
                    keyboardType: TextInputType.multiline,
                    minLines: 1,
                    maxLines: 10,
                    style: const TextStyle(fontSize: 15, color: Colors.black87),
                    decoration: const InputDecoration(
                      hintText: "Ask anything, @ to mention, / for workflows",
                      hintStyle: TextStyle(color: Color(0xFFAEB1B7), fontSize: 15),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12.0,
                        vertical: 12.0,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 8, bottom: 4),
                    child: Row(
                      children: [
                        // + Icon
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.add, color: Color(0xFF999999), size: 20),
                          onPressed: () async {
                            FilePickerResult? result = await FilePicker.platform.pickFiles(
                              allowMultiple: true,
                            );
                            if (result != null) {
                              logger.d('Picked files: ${result.paths}');
                            }
                          },
                        ),
                        const SizedBox(width: 12),
                        // Model Dropdown
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
                                child: Icon(Icons.keyboard_arrow_up, size: 16, color: Color(0xFF8E8E93)),
                              ),
                              elevation: 2,
                              onChanged: (String? newValue) {
                                if (newValue != null) {
                                  setState(() {
                                    _selectedModel = newValue;
                                  });
                                }
                              },
                              items: _models.map<DropdownMenuItem<String>>((String value) {
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
                              }).toList(),
                            ),
                          ),
                        ),
                        const Spacer(),
                        // Voice Icon

                        // Send Icon (Arrow in circle)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFD1D1D6),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: const Icon(
                              Icons.arrow_forward_rounded,
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
