import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:uuid/uuid.dart';

final _uuid = const Uuid();

Email makeTestEmail({
  String? id,
  String collectionId = 'col-1',
  DateTime? date,
  String from = 'sender@example.com',
  List<String>? to,
  List<String>? cc,
  String? subject = 'Test Subject',
  String? snippet = 'Test snippet',
  String? htmlBody,
  String? plainBody = 'Test body',
  List<String>? labels,
  String? folderId = 'inbox',
  String? messageId,
  String? threadId,
  int? uid,
  bool isRead = false,
  bool hasAttachments = false,
  bool isDeleted = false,
}) {
  return Email(
    id: id ?? _uuid.v4(),
    collectionId: collectionId,
    date: date ?? DateTime(2024, 1, 1),
    from: from,
    to: to ?? ['recipient@example.com'],
    cc: cc ?? [],
    subject: subject,
    snippet: snippet,
    htmlBody: htmlBody,
    plainBody: plainBody,
    labels: labels ?? [],
    folderId: folderId,
    messageId: messageId ?? _uuid.v4(),
    threadId: threadId ?? _uuid.v4(),
    uid: uid,
    isRead: isRead,
    hasAttachments: hasAttachments,
    isDeleted: isDeleted,
  );
}

EmailFolder makeTestEmailFolder({
  String? id,
  String collectionId = 'col-1',
  String name = 'Inbox',
  String type = 'system',
  int? messagesTotal,
  int? messagesUnread,
  String? parentId,
}) {
  return EmailFolder(
    id: id ?? _uuid.v4(),
    collectionId: collectionId,
    name: name,
    type: type,
    messagesTotal: messagesTotal,
    messagesUnread: messagesUnread,
    parentId: parentId,
  );
}
