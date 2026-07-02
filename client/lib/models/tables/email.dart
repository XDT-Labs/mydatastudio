import 'package:mydatastudio/models/tables/file.dart';

class Email {
  String id;
  String collectionId;
  DateTime date;
  String from;
  List<String> to;
  List<String>? cc = [];
  String? subject;
  String? snippet;
  String? htmlBody;
  String? plainBody;
  List<String>? labels = [];
  String? headers;
  List<File>? attachments = [];
  String? folderId;
  String? messageId;
  String? threadId;
  int? uid;
  bool isRead = false;
  bool hasAttachments = false;
  bool isDeleted = false;

  //Not in db
  bool? isSelected = false;

  Email({
    required this.id,
    required this.collectionId,
    required this.date,
    required this.from,
    required this.to,
    this.cc,
    this.subject,
    this.snippet,
    this.htmlBody,
    this.plainBody,
    this.labels,
    this.headers,
    this.attachments,
    this.folderId,
    this.messageId,
    this.threadId,
    this.uid,
    this.isRead = false,
    this.hasAttachments = false,
    required this.isDeleted,
    this.isSelected,
  });

  factory Email.fromDbMap(Map<String, dynamic> map) {
    final toStr = map['to'] as String? ?? '';
    final ccStr = map['cc'] as String? ?? '';
    final labelsStr = map['labels'] as String? ?? '';

    return Email(
      id: map['id'] as String,
      collectionId: map['collection_id'] as String,
      date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
      from: map['from'] as String? ?? '',
      to: toStr.isEmpty ? [] : toStr.split(','),
      cc: ccStr.isEmpty ? [] : ccStr.split(','),
      subject: map['subject'] as String?,
      snippet: map['snippet'] as String?,
      htmlBody: map['html_body'] as String?,
      plainBody: map['plain_body'] as String?,
      labels: labelsStr.isEmpty ? [] : labelsStr.split(','),
      headers: map['headers'] as String?,
      folderId: map['folder_id'] as String?,
      messageId: map['message_id'] as String?,
      threadId: map['thread_id'] as String?,
      uid: map['uid'] as int?,
      isRead: (map['is_read'] as int? ?? 0) != 0,
      hasAttachments: (map['has_attachments'] as int? ?? 0) != 0,
      isDeleted: (map['is_deleted'] as int? ?? 0) != 0,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'collection_id': collectionId,
      'date': date.millisecondsSinceEpoch,
      'from': from,
      'to': to.join(','),
      'cc': (cc ?? []).join(','),
      'subject': subject,
      'snippet': snippet,
      'html_body': htmlBody,
      'plain_body': plainBody,
      'labels': (labels ?? []).join(','),
      'headers': headers,
      'folder_id': folderId,
      'message_id': messageId,
      'thread_id': threadId,
      'uid': uid,
      'is_read': isRead ? 1 : 0,
      'has_attachments': hasAttachments ? 1 : 0,
      'is_deleted': isDeleted ? 1 : 0,
    };
  }

  @override
  String toString() {
    return '_Email{id: $id, from: $from, to: $to, cc: $cc, subject: $subject}';
  }
}
