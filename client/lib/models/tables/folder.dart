import 'package:mydatatools/models/tables/file_asset.dart';

class Folder implements FileAsset {
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

  factory Folder.fromDbMap(Map<String, dynamic> map) {
    return Folder(
      id: map['id'] as String,
      name: map['name'] as String,
      path: map['path'] as String,
      parent: map['parent'] as String,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(map['date_created'] as int),
      dateLastModified: DateTime.fromMillisecondsSinceEpoch(map['date_last_modified'] as int),
      lastScannedDate: map['last_scanned_date'] != null ? DateTime.fromMillisecondsSinceEpoch(map['last_scanned_date'] as int) : null,
      collectionId: map['collection_id'] as String,
      thumbnail: map['thumbnail'] as String?,
      downloadUrl: map['download_url'] as String?,
      emailId: map['email_id'] as String?,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'parent': parent,
      'date_created': dateCreated.millisecondsSinceEpoch,
      'date_last_modified': dateLastModified.millisecondsSinceEpoch,
      'last_scanned_date': lastScannedDate?.millisecondsSinceEpoch,
      'collection_id': collectionId,
      'thumbnail': thumbnail,
      'download_url': downloadUrl,
      'email_id': emailId,
    };
  }
}
