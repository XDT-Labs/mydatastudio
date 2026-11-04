class EmailFolder {
  final String id;
  final String collectionId;
  final String name;
  final String type;
  final int? messagesTotal;
  final int? messagesUnread;
  final String? parentId;

  /// Full IMAP path (the delimiter-joined name). Null for non-IMAP folders and
  /// rows written before this column existed.
  final String? path;

  /// IMAP sync state; see RFC 3501 UIDVALIDITY/UIDNEXT and RFC 7162 HIGHESTMODSEQ.
  final int? uidValidity;
  final int? uidNext;
  final int? highestModseq;
  final int? lastSyncedUid;

  EmailFolder({
    required this.id,
    required this.collectionId,
    required this.name,
    this.type = 'user',
    this.messagesTotal,
    this.messagesUnread,
    this.parentId,
    this.path,
    this.uidValidity,
    this.uidNext,
    this.highestModseq,
    this.lastSyncedUid,
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
      path: map['path'] as String?,
      uidValidity: map['uid_validity'] as int?,
      uidNext: map['uid_next'] as int?,
      highestModseq: map['highest_modseq'] as int?,
      lastSyncedUid: map['last_synced_uid'] as int?,
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
      'path': path,
      'uid_validity': uidValidity,
      'uid_next': uidNext,
      'highest_modseq': highestModseq,
      'last_synced_uid': lastSyncedUid,
    };
  }
}
