import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/aichat_conversation.dart';
import 'package:mydatastudio/modules/aichat/pages/aichat_page.dart';
import 'package:mydatastudio/repositories/aichat_repository.dart';

const _drawerBg = Color(0xFF0A0A0A);
const _drawerBorder = Color(0xFF2C2C2E);
const _activeItemBg = Color(0xFF1C1C1E);
const _textPrimary = Colors.white;
const _textMuted = Color(0xFF8E8E93);
const _accentColor = Color(0xFF636366);
const _newBtnBg = Color(0xFF1C1C1E);
const _newBtnBorder = Color(0xFF3A3A3C);

class AiChatDrawer extends StatefulWidget {
  const AiChatDrawer({super.key});

  @override
  State<AiChatDrawer> createState() => _AiChatDrawerState();
}

class _AiChatDrawerState extends State<AiChatDrawer> {
  List<AichatConversation> _conversations = [];
  StreamSubscription? _sub;
  String? _activeId;

  AichatRepository? get _repo {
    final db = DatabaseManager.instance.database;
    if (db == null) return null;
    return AichatRepository(db);
  }

  @override
  void initState() {
    super.initState();
    _subscribeToConversations();
    AichatPage.selectConversationId.addListener(_onActiveChanged);
  }

  @override
  void dispose() {
    _sub?.cancel();
    AichatPage.selectConversationId.removeListener(_onActiveChanged);
    super.dispose();
  }

  void _onActiveChanged() {
    if (mounted) {
      setState(() => _activeId = AichatPage.selectConversationId.value);
    }
  }

  void _subscribeToConversations() {
    final repo = _repo;
    if (repo == null) {
      // DB not ready yet — retry after the frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _subscribeToConversations();
      });
      return;
    }
    _sub = repo.watchConversations().listen((convs) {
      if (mounted) setState(() => _conversations = convs);
    });
  }

  void _selectConversation(AichatConversation conv) {
    setState(() => _activeId = conv.id);
    AichatPage.selectConversationId.value = conv.id;
  }

  void _newConversation() {
    setState(() => _activeId = null);
    // Use a non-null sentinel first so the ValueNotifier always fires,
    // even when the current value is already null.
    AichatPage.selectConversationId.value = '__new__';
    AichatPage.selectConversationId.value = null;
  }

  Future<void> _deleteConversation(AichatConversation conv) async {
    final repo = _repo;
    if (repo == null) return;
    await repo.deleteConversation(conv.id);
    if (_activeId == conv.id) {
      _newConversation();
    }
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AichatPage.isStreaming,
      builder: (context, streaming, _) => _buildContent(streaming),
    );
  }

  Widget _buildContent(bool streaming) {
    return Container(
      color: _drawerBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
            child: GestureDetector(
              onTap: streaming ? null : _newConversation,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _newBtnBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _newBtnBorder, width: 0.5),
                ),
                child: Row(
                  children: [
                    Icon(Icons.add, color: streaming ? _accentColor : _textMuted, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      'New Conversation',
                      style: TextStyle(
                        color: streaming ? _accentColor : _textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Divider
          Container(height: 0.5, color: _drawerBorder),

          // Conversation list
          Expanded(
            child: _conversations.isEmpty
                ? const Center(
                    child: Text(
                      'No conversations yet',
                      style: TextStyle(color: _textMuted, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _conversations.length,
                    itemBuilder: (context, index) {
                      final conv = _conversations[index];
                      final isActive = conv.id == _activeId;
                      return _ConversationTile(
                        conversation: conv,
                        isActive: isActive,
                        disabled: streaming,
                        formattedDate: _formatDate(conv.updatedAt),
                        onTap: () => _selectConversation(conv),
                        onDelete: () => _deleteConversation(conv),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatefulWidget {
  final AichatConversation conversation;
  final bool isActive;
  final bool disabled;
  final String formattedDate;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ConversationTile({
    required this.conversation,
    required this.isActive,
    required this.disabled,
    required this.formattedDate,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.disabled ? null : widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.isActive
                ? _activeItemBg
                : _hovering
                    ? const Color(0xFF141414)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.conversation.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.isActive ? _textPrimary : const Color(0xFFE5E5EA),
                        fontSize: 13,
                        fontWeight: widget.isActive ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.formattedDate,
                      style: const TextStyle(color: _textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if ((_hovering || widget.isActive) && !widget.disabled)
                GestureDetector(
                  onTap: widget.onDelete,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.close, size: 14, color: _accentColor),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
