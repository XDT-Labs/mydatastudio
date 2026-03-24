import 'package:drift/drift.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/collection.dart';

@UseRowClass(EmailFolder, constructor: 'fromDb')
@TableIndex(name: 'email_folders_id_idx', columns: {#id})
@TableIndex(name: 'email_folders_collectionid_idx', columns: {#collectionId})
class EmailFolders extends Table {
  TextColumn get id => text()(); // Gmail labelId, IMAP mailbox path, etc.
  TextColumn get collectionId => text().references(Collections, #id)();
  TextColumn get name => text()();
  TextColumn get type => text().withDefault(const Constant('user'))(); // 'system' or 'user'
  IntColumn get messagesTotal => integer().nullable()();
  IntColumn get messagesUnread => integer().nullable()();
  TextColumn get parentId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id, collectionId};
}

class EmailFolder implements Insertable<EmailFolder> {
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

  EmailFolder.fromDb({
    required this.id,
    required this.collectionId,
    required this.name,
    required this.type,
    this.messagesTotal,
    this.messagesUnread,
    this.parentId,
  });

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    return EmailFoldersCompanion(
      id: Value(id),
      collectionId: Value(collectionId),
      name: Value(name),
      type: Value(type),
      messagesTotal: Value(messagesTotal),
      messagesUnread: Value(messagesUnread),
      parentId: Value(parentId),
    ).toColumns(nullToAbsent);
  }
}
