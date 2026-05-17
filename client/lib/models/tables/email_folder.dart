class EmailFolder {
  final String id;
  final String collectionId;
  final String name;
  final String type;
  final int? messagesTotal;
  final int? messagesUnread;
  final String? parentId;

  EmailFolder({
    required this.id,
    required this.collectionId,
    required this.name,
    this.type = 'user',
    this.messagesTotal,
    this.messagesUnread,
    this.parentId,
  });

  factory EmailFolder.fromDbMap(Map<String, dynamic> map) {
    return EmailFolder(
      id: map['id'] as String,
      collectionId: map['collection_id'] as String,
      name: map['name'] as String,
      type: map['type'] as String? ?? 'user',
      messagesTotal: map['messages_total'] as int?,
      messagesUnread: map['messages_unread'] as int?,
      parentId: map['parent_id'] as String?,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'collection_id': collectionId,
      'name': name,
      'type': type,
      'messages_total': messagesTotal,
      'messages_unread': messagesUnread,
      'parent_id': parentId,
    };
  }
}
