import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:genui/genui.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/app_router.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/aichat/services/local_llm_content_generator.dart';
import 'package:mydatastudio/python_manager.dart';
import 'package:mydatastudio/services/model_download_manager.dart';
import 'package:mydatastudio/models/tables/aichat_model.dart';
import 'package:mydatastudio/repositories/aichat_model_repository.dart';
import 'package:mydatastudio/repositories/aichat_repository.dart';
import 'package:mydatastudio/repositories/aichat_skills_repository.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async';

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

  /// Drawer writes here to load a conversation (null = new conversation).
  static final ValueNotifier<String?> selectConversationId = ValueNotifier(
    null,
  );

  /// True while an LLM response is streaming — navigation is disabled during this time.
  static final ValueNotifier<bool> isStreaming = ValueNotifier(false);

  @override
  State<AichatPage> createState() => _AichatPage();
}

sealed class ChatItem {}

class TextMessageItem extends ChatItem {
  final String role;
  final String text;
  final String? model;
  final List<Uint8List> images;
  final Map<String, int>? usage;
  TextMessageItem({required this.role, required this.text, this.model, this.images = const [], this.usage});
}

class GenUiSurfaceItem extends ChatItem {
  final String surfaceId;
  GenUiSurfaceItem({required this.surfaceId});
}

class _AichatPage extends State<AichatPage> with RouteAware {
  AppLogger logger = AppLogger(null);
  bool _isLLMServiceRunning = PythonManager.isLLMServiceRunning.value;
  bool _modelsReady = ModelDownloadManager.isReady.value;
  List<ModelDownloadItem> _downloadItems = ModelDownloadManager.items.value;
  String _selectedModel = 'gemma4:12b';
  List<AichatModel> _dbModels = [];
  StreamSubscription<List<AichatModel>>? _modelsSub;

  final _textController = TextEditingController();
  final _titleController = TextEditingController();
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

  // Current conversation being viewed/edited.
  String? _conversationId;

  AichatRepository? get _repo {
    final db = DatabaseManager.instance.database;
    if (db == null) return null;
    return AichatRepository(db);
  }

  bool get _canSend =>
      _textController.text.trim().isNotEmpty || _pendingFiles.isNotEmpty;

  /// Sum of total_tokens across all cloud-model assistant responses this session.
  /// Local models return -1 for usage; those are excluded from the count.
  int get _sessionTotalTokens {
    int total = 0;
    for (final item in _chatItems) {
      if (item is TextMessageItem && item.role == 'assistant') {
        final t = item.usage?['total_tokens'] ?? 0;
        if (t > 0) total += t;
      }
    }
    return total;
  }

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

    ModelDownloadManager.isReady.addListener(_onModelsReadyChanged);
    ModelDownloadManager.items.addListener(_onDownloadItemsChanged);

    AichatPage.selectConversationId.addListener(_onConversationSelected);
    _loadDbModels();

    _a2uiMessageProcessor = A2uiMessageProcessor(
      catalogs: [CoreCatalogItems.asCatalog()],
    );

    _contentGenerator = LocalLlmContentGenerator(
      systemInstruction: 'You are a helpful assistant.',
    );

    _contentGenerator.streamingChunkStream.listen((chunk) {
      if (mounted) {
        AichatPage.isStreaming.value = true;
        setState(() {
          _streamingText = (_streamingText ?? '') + chunk;
        });
        _scrollToBottom();
      }
    });

    _contentGenerator.textResponseStream.listen((text) {
      if (mounted) {
        setState(() {
          _chatItems.add(TextMessageItem(
            role: 'assistant',
            text: text,
            model: _contentGenerator.lastResponseModel,
            usage: _contentGenerator.lastUsage,
          ));
          _streamingText = null;
        });
        AichatPage.isStreaming.value = false;
        _persistAssistantMessage(text);
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
        AichatPage.isStreaming.value = false;
        if (mounted) setState(() => _streamingText = null);
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      AppRouter.routeObserver.subscribe(this, route);
    }
  }

  /// Called when the settings page (or any page pushed on top) is popped and
  /// this page comes back into view. Re-fetches models so API key changes are
  /// picked up immediately without requiring a full restart.
  @override
  void didPopNext() {
    _reloadModels();
  }

  void _onModelsReadyChanged() {
    if (!mounted) return;
    setState(() => _modelsReady = ModelDownloadManager.isReady.value);
  }

  void _onDownloadItemsChanged() {
    if (!mounted) return;
    setState(() => _downloadItems = ModelDownloadManager.items.value);
  }

  Future<void> _reloadModels() async {
    final db = DatabaseManager.instance.database;
    if (db == null || !mounted) return;
    final models = await AichatModelRepository(db).getAll();
    if (mounted) setState(() => _dbModels = models);
  }

  @override
  void dispose() {
    AppRouter.routeObserver.unsubscribe(this);
    _modelsSub?.cancel();
    ModelDownloadManager.isReady.removeListener(_onModelsReadyChanged);
    ModelDownloadManager.items.removeListener(_onDownloadItemsChanged);
    AichatPage.selectConversationId.removeListener(_onConversationSelected);
    _textController.dispose();
    _titleController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _genUiConversation.dispose();
    super.dispose();
  }

  void _loadDbModels() {
    final db = DatabaseManager.instance.database;
    if (db == null) return;
    final repo = AichatModelRepository(db);
    _modelsSub = repo.watchAll().listen((models) {
      if (!mounted) return;
      setState(() {
        _dbModels = models;
      });
    });
  }

  /// Ordered group labels for the dropdown headers.
  static const List<(String, String)> _groupOrder = [
    ('local', 'Local LLM'),
    ('ollama', 'Ollama'),
    ('gemini', 'Gemini'),
    ('claude', 'Claude'),
    ('openai', 'OpenAI'),
    ('grok', 'Grok'),
  ];

  List<DropdownMenuItem<String>> _buildModelItems() {
    final items = <DropdownMenuItem<String>>[];

    for (final (group, label) in _groupOrder) {
      final groupModels =
          _dbModels.where((m) => m.group == group && m.enabled).toList();
      if (groupModels.isEmpty) continue;

      // Header (not selectable)
      items.add(
        DropdownMenuItem<String>(
          enabled: false,
          value: '__header_$group',
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: _hintColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
      );

      for (final m in groupModels) {
        items.add(
          DropdownMenuItem<String>(
            value: m.alias,
            child: Text(
              m.name,
              style: const TextStyle(color: _mutedColor, fontSize: 13),
            ),
          ),
        );
      }
    }

    return items;
  }

  void _onConversationSelected() {
    final id = AichatPage.selectConversationId.value;
    if (id == null) {
      _startNewConversation();
    } else if (id != '__new__') {
      _loadConversation(id);
    }
  }

  void _startNewConversation() {
    if (!mounted) return;
    setState(() {
      _conversationId = null;
      _chatItems.clear();
      _streamingText = null;
      _titleController.text = '';
    });
    _contentGenerator.clearHistory();
  }

  Future<void> _loadConversation(String id) async {
    final repo = _repo;
    if (repo == null) return;

    final messages = await repo.getMessages(id);
    if (!mounted) return;

    // Rebuild display list and LLM history from persisted messages
    final chatItems = <TextMessageItem>[];
    final llmHistory = <Map<String, dynamic>>[];
    String conversationName = '';

    for (final m in messages) {
      final usage = (m.tokenCount != null && m.tokenCount! > 0)
          ? {'total_tokens': m.tokenCount!}
          : null;
      chatItems.add(TextMessageItem(role: m.role, text: m.content, usage: usage));
      llmHistory.add({'role': m.role, 'content': m.content});
    }

    // Fetch the conversation name
    final rows = await DatabaseManager.instance.database?.select(
      'SELECT name, model FROM aichat_conversations WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows != null && rows.isNotEmpty) {
      conversationName = rows.first['name'] as String? ?? '';
      final savedModel = rows.first['model'] as String?;
      if (savedModel != null && mounted) {
        setState(() => _selectedModel = savedModel);
      }
    }

    _contentGenerator.loadHistory(llmHistory);

    setState(() {
      _conversationId = id;
      _chatItems
        ..clear()
        ..addAll(chatItems);
      _streamingText = null;
      _titleController.text = conversationName;
    });

    _scrollToBottom();
  }

  /// Creates a conversation record on first message if not yet created.
  Future<void> _ensureConversation(String firstMessage) async {
    if (_conversationId != null) return;
    final repo = _repo;
    if (repo == null) return;

    final name = _defaultName(firstMessage);
    final alias = _selectedModel;
    final conv = await repo.createConversation(name: name, model: alias);

    if (mounted) {
      setState(() {
        _conversationId = conv.id;
        _titleController.text = conv.name;
      });
    }
  }

  Future<void> _persistAssistantMessage(String text) async {
    final id = _conversationId;
    final repo = _repo;
    if (id == null || repo == null) return;
    final t = _contentGenerator.lastUsage?['total_tokens'] ?? 0;
    await repo.addMessage(
      conversationId: id,
      role: 'assistant',
      content: text,
      tokenCount: t > 0 ? t : null,
    );
    // Keep model in sync
    final alias = _selectedModel;
    await repo.updateConversation(id, model: alias);
  }

  String _defaultName(String message) {
    final words = message.trim().split(RegExp(r'\s+'));
    final snippet = words.take(6).join(' ');
    return snippet.length > 50 ? snippet.substring(0, 50) : snippet;
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

    // Resolve /command skill: inject system prompt and strip the trigger word.
    String llmMessage = message;
    if (message.trimLeft().startsWith('/')) {
      final db = DatabaseManager.instance.database;
      if (db != null) {
        final parts = message.trim().split(RegExp(r'\s+'));
        final trigger = parts.first;
        final skill = await AichatSkillsRepository(db).getByTrigger(trigger);
        if (skill != null) {
          _contentGenerator.skillSystemPrompt = skill.systemPrompt;
          llmMessage = parts.length > 1 ? parts.sublist(1).join(' ') : '';
        }
      }
    }

    // Create conversation on first message
    await _ensureConversation(message);

    List<Uint8List> attachmentBytes = [];
    if (_pendingFiles.isNotEmpty) {
      logger.d(
        '[ATTACH] Reading ${_pendingFiles.length} file(s): ${_pendingFiles.map((f) => f.name).toList()}',
      );
      attachmentBytes = await Future.wait(
        _pendingFiles
            .where((f) => f.path != null)
            .map((f) => File(f.path!).readAsBytes()),
      );
      logger.d('[ATTACH] Read ${attachmentBytes.length} file(s)');
      _contentGenerator.pendingAttachments = attachmentBytes;
    }

    setState(() {
      _chatItems.add(TextMessageItem(role: 'user', text: message, images: attachmentBytes));
      _pendingFiles.clear();
    });

    // Persist user message
    final id = _conversationId;
    final repo = _repo;
    if (id != null && repo != null) {
      await repo.addMessage(conversationId: id, role: 'user', content: message);
    }

    final alias = _selectedModel;
    _contentGenerator.model = alias;
    // Pass file paths for downloaded local models so the server can load
    // them directly without needing a registry entry.
    final selectedDbModel =
        _dbModels.where((m) => m.alias == _selectedModel).firstOrNull;
    _contentGenerator.modelPath = selectedDbModel?.file;
    _contentGenerator.mmprojPath = selectedDbModel?.mmproj;

    // API keys live in the providers table, keyed by the model's group name.
    String? apiKey;
    final group = selectedDbModel?.group;
    if (group != null) {
      final db = DatabaseManager.instance.database;
      if (db != null) {
        final rows = await db.select(
          'SELECT api_key FROM providers WHERE service = ? LIMIT 1',
          [group],
        );
        if (rows.isNotEmpty) apiKey = rows.first['api_key'] as String?;
      }
    }
    _contentGenerator.apiKey = apiKey;

    _genUiConversation.sendRequest(UserMessage.text(llmMessage.isEmpty ? message : llmMessage));
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

  Widget _buildUserBubble(String text, {List<Uint8List> images = const []}) {
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (images.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: text.isNotEmpty ? 8.0 : 0),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: images
                        .map(
                          (bytes) => ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              bytes,
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              if (text.isNotEmpty)
                Text(
                  text,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantBubble(String text, {bool streaming = false, String? model}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (model != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  model,
                  style: const TextStyle(color: _hintColor, fontSize: 11),
                ),
              ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.85,
              ),
              child: MarkdownBody(
                data: streaming ? '$text▋' : text,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.5,
                  ),
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
                  h1: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  h2: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  h3: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  listBullet: const TextStyle(color: Colors.white),
                  strong: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  em: const TextStyle(
                    color: Color(0xFFE5E5EA),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTokens(int count) {
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(count % 1000 == 0 ? 0 : 1)}k';
    }
    return count.toString();
  }

  Widget _buildTitleBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      decoration: const BoxDecoration(
        color: _bgColor,
        border: Border(
          bottom: BorderSide(color: _inputBorderColor, width: 0.5),
        ),
      ),
      child: TextField(
        controller: _titleController,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        decoration: const InputDecoration(
          hintText: 'New conversation',
          hintStyle: TextStyle(
            color: _hintColor,
            fontSize: 16,
            fontWeight: FontWeight.w400,
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: (value) => _saveTitleChange(value),
        onEditingComplete: () => _saveTitleChange(_titleController.text),
      ),
    );
  }

  Future<void> _saveTitleChange(String value) async {
    final id = _conversationId;
    final repo = _repo;
    final trimmed = value.trim();
    if (id == null || repo == null || trimmed.isEmpty) return;
    await repo.updateConversation(id, name: trimmed);
  }

  Widget _buildModelDownloadGate() {
    final hasError =
        _downloadItems.any((i) => i.status == ModelDownloadStatus.error);

    return ColoredBox(
      color: _bgColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Setting up AI Chat',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Downloading models for the first time. This only happens once.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _mutedColor, fontSize: 13),
              ),
              const SizedBox(height: 24),
              ..._downloadItems.map(_buildDownloadItemTile),
              if (hasError) ...[
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => ModelDownloadManager.instance.retry(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadItemTile(ModelDownloadItem item) {
    String statusText;
    switch (item.status) {
      case ModelDownloadStatus.pending:
        statusText = 'Waiting…';
        break;
      case ModelDownloadStatus.checking:
        statusText = 'Checking…';
        break;
      case ModelDownloadStatus.downloading:
        statusText = item.totalMb > 0
            ? '${item.downloadedMb.toStringAsFixed(0)} MB / ${item.totalMb.toStringAsFixed(0)} MB'
            : 'Starting download…';
        break;
      case ModelDownloadStatus.complete:
        statusText = 'Ready';
        break;
      case ModelDownloadStatus.error:
        statusText = item.error ?? 'Download failed';
        break;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildDownloadStatusIcon(item.status),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (item.status == ModelDownloadStatus.downloading)
            LinearProgressIndicator(
              value: item.progress > 0 ? item.progress : null,
              backgroundColor: _inputBorderColor,
            ),
          const SizedBox(height: 4),
          Text(
            statusText,
            style: TextStyle(
              color: item.status == ModelDownloadStatus.error
                  ? Colors.redAccent
                  : _mutedColor,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadStatusIcon(ModelDownloadStatus status) {
    switch (status) {
      case ModelDownloadStatus.complete:
        return const Icon(Icons.check_circle, color: Colors.greenAccent, size: 18);
      case ModelDownloadStatus.error:
        return const Icon(Icons.error_outline, color: Colors.redAccent, size: 18);
      case ModelDownloadStatus.downloading:
      case ModelDownloadStatus.checking:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: _mutedColor),
        );
      case ModelDownloadStatus.pending:
        return const Icon(Icons.schedule, color: _mutedColor, size: 18);
    }
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

    if (!_modelsReady) {
      return _buildModelDownloadGate();
    }

    final itemCount = _chatItems.length + (_streamingText != null ? 1 : 0);

    return Scaffold(
      backgroundColor: _bgColor,
      body: Column(
        children: [
          _buildTitleBar(),
          Expanded(
            child: SelectionArea(
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
                      ? _buildUserBubble(item.text, images: item.images)
                      : _buildAssistantBubble(item.text, model: item.model);
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
          ),
          Container(
            color: _bgColor,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_sessionTotalTokens > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 6, 4, 4),
                    child: Text(
                      '${_formatTokens(_sessionTotalTokens)} total tokens',
                      style: const TextStyle(color: _mutedColor, fontSize: 11),
                    ),
                  )
                else
                  const SizedBox(height: 8),
                Container(
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
                      style: const TextStyle(fontSize: 15, color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: "Ask a question",
                        hintStyle: TextStyle(color: _hintColor, fontSize: 15),
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
                        children:
                            _pendingFiles.map((f) {
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
                                onDeleted:
                                    () =>
                                        setState(() => _pendingFiles.remove(f)),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
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
                            FilePickerResult? result = await FilePicker.platform
                                .pickFiles(allowMultiple: true);
                            if (result != null) {
                              setState(
                                () => _pendingFiles.addAll(result.files),
                              );
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
                              value: _buildModelItems().any((i) => i.value == _selectedModel) ? _selectedModel : null,
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
                              items: _buildModelItems(),
                            ),
                          ),
                        ),
                        const Spacer(),
                        if (_streamingText != null)
                          GestureDetector(
                            onTap: () => _contentGenerator.cancelStream(),
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: _sendEnabledBg,
                              ),
                              child: const Icon(
                                Icons.stop_rounded,
                                color: Colors.black,
                                size: 18,
                              ),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: _canSend
                                ? () => _sendMessage(_textController.text)
                                : null,
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _canSend ? _sendEnabledBg : _sendDisabledBg,
                              ),
                              child: Icon(
                                Icons.arrow_upward_rounded,
                                color: _canSend ? Colors.black : _mutedColor,
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
