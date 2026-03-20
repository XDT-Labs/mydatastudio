import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:drift/drift.dart';

//part 'folder.g.dart';

@UseRowClass(Folder, constructor: 'fromDb')
@TableIndex(name: 'folder_path_idx', columns: {#path})
@TableIndex(name: 'folder_parent_idx', columns: {#parent})
@TableIndex(name: 'folder_collection_id_idx', columns: {#collectionId})
@TableIndex(name: 'folder_email_id_idx', columns: {#emailId})
class Folders extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get path => text()();
  TextColumn get parent => text()();
  DateTimeColumn get dateCreated => dateTime()();
  DateTimeColumn get dateLastModified => dateTime()();
  DateTimeColumn get lastScannedDate => dateTime().nullable()();
  TextColumn get thumbnail => text().nullable()();
  TextColumn get downloadUrl => text().nullable()();
  TextColumn get emailId => text().nullable()();
  TextColumn get collectionId => text()();

  @override
  Set<Column> get primaryKey => {id};
}

class Folder implements FileAsset, Insertable<Folder> {
  @override
  String id;
  @override
  String name;
  @override
  String path;
  @override
  String parent;
  @override
  DateTime dateCreated;
  @override
  DateTime dateLastModified;
  @override
  DateTime? lastScannedDate;
  @override
  String collectionId;
  String? thumbnail;
  String? downloadUrl;
  String? emailId;

  Folder({
    required this.id,
    required this.name,
    required this.path,
    required this.parent,
    required this.dateCreated,
    required this.dateLastModified,
    this.lastScannedDate,
    required this.collectionId,
    this.thumbnail,
    this.downloadUrl,
    this.emailId,
  });

  Folder.fromDb({
    required this.id,
    required this.name,
    required this.path,
    required this.parent,
    required this.dateCreated,
    required this.dateLastModified,
    this.lastScannedDate,
    required this.collectionId,
    this.thumbnail,
    this.downloadUrl,
    this.emailId,
  });

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    return FoldersCompanion(
      id: Value(id),
      name: Value(name),
      path: Value(path),
      parent: Value(parent),
      dateCreated: Value(dateCreated),
      dateLastModified: Value(dateLastModified),
      lastScannedDate: Value(lastScannedDate),
      collectionId: Value(collectionId),
      thumbnail: Value(thumbnail),
      downloadUrl: Value(downloadUrl),
      emailId: Value(emailId),
    ).toColumns(nullToAbsent);
  }
}
