class AichatMessage {
  final String id;
  final String conversationId;
  final String role; // 'user', 'assistant', 'system'
  final String content;
  final DateTime createdAt;
  final int? tokenCount;

  AichatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.tokenCount,
  });

  factory AichatMessage.fromDbMap(Map<String, dynamic> map) {
    return AichatMessage(
      id: map['id'] as String,
      conversationId: map['conversation_id'] as String,
      role: map['role'] as String,
      content: map['content'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      tokenCount: map['token_count'] as int?,
    );
  }
}
