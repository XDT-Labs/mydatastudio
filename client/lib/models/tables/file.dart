import 'package:mydatastudio/models/tables/file_asset.dart';

class File implements FileAsset {
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
  String contentType; //mime/type
  int size;
  bool isDeleted;
  String? thumbnail;
  String? downloadUrl;
  String? emailId;
  double? latitude;
  double? longitude;
  String? localPath;

  File({
    required this.id,
    required this.name,
    required this.path,
    required this.parent,
    required this.dateCreated,
    required this.dateLastModified,
    this.lastScannedDate,
    required this.collectionId,
    required this.contentType,
    required this.size,
    required this.isDeleted,
    this.thumbnail,
    this.downloadUrl,
    this.emailId,
    this.latitude,
    this.longitude,
    this.localPath,
  });

  factory File.fromDbMap(Map<String, dynamic> map) {
    return File(
      id: map['id'] as String,
      name: map['name'] as String,
      path: map['path'] as String,
      parent: map['parent'] as String,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(
        map['date_created'] as int,
      ),
      dateLastModified: DateTime.fromMillisecondsSinceEpoch(
        map['date_last_modified'] as int,
      ),
      lastScannedDate:
          map['last_scanned_date'] != null
              ? DateTime.fromMillisecondsSinceEpoch(
                map['last_scanned_date'] as int,
              )
              : null,
      collectionId: map['collection_id'] as String,
      contentType: map['content_type'] as String,
      size: map['size'] as int,
      isDeleted: (map['is_deleted'] as int? ?? 0) != 0,
      thumbnail: map['thumbnail'] as String?,
      downloadUrl: map['download_url'] as String?,
      emailId: map['email_id'] as String?,
      latitude:
          map['latitude'] != null ? (map['latitude'] as num).toDouble() : null,
      longitude:
          map['longitude'] != null
              ? (map['longitude'] as num).toDouble()
              : null,
      localPath: map['local_path'] as String?,
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
      'content_type': contentType,
      'size': size,
      'is_deleted': isDeleted ? 1 : 0,
      'thumbnail': thumbnail,
      'download_url': downloadUrl,
      'email_id': emailId,
      'latitude': latitude,
      'longitude': longitude,
      'local_path': localPath,
    };
  }
}
