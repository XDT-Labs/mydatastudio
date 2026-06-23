import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:uuid/uuid.dart';

final _uuid = const Uuid();

File makeTestFile({
  String? id,
  String name = 'test.jpg',
  String path = '/tmp/test.jpg',
  String parent = '/tmp',
  String collectionId = 'col-1',
  String contentType = 'image/jpeg',
  int size = 1024,
  bool isDeleted = false,
  String? thumbnail,
  String? downloadUrl,
  String? emailId,
  double? latitude,
  double? longitude,
  DateTime? dateCreated,
  DateTime? dateLastModified,
  DateTime? lastScannedDate,
}) {
  final now = DateTime(2024, 1, 1);
  return File(
    id: id ?? _uuid.v4(),
    name: name,
    path: path,
    parent: parent,
    collectionId: collectionId,
    contentType: contentType,
    size: size,
    isDeleted: isDeleted,
    thumbnail: thumbnail,
    downloadUrl: downloadUrl,
    emailId: emailId,
    latitude: latitude,
    longitude: longitude,
    dateCreated: dateCreated ?? now,
    dateLastModified: dateLastModified ?? now,
    lastScannedDate: lastScannedDate,
  );
}

Collection makeTestCollection({
  String? id,
  String name = 'Test Collection',
  String path = '/tmp/collection',
  String type = 'local',
  String scanner = 'local_file',
  String scanStatus = 'idle',
  bool needsReAuth = false,
  String? localCopyPath,
}) {
  return Collection(
    id: id ?? _uuid.v4(),
    name: name,
    path: path,
    type: type,
    scanner: scanner,
    scanStatus: scanStatus,
    needsReAuth: needsReAuth,
    localCopyPath: localCopyPath,
  );
}
