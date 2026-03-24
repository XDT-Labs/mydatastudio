/// A provider-agnostic representation of a file or folder returned by a
/// [FileSourceProvider]. This is a lightweight DTO used for listing and UI
/// actions — it is intentionally separate from the DB model ([File]/[Folder])
/// so the provider layer does not depend on Drift/SQLite.
class FileSourceFile {
  /// Provider-native identifier.
  /// - Local files: the absolute filesystem path.
  /// - Google Drive: the Drive file ID.
  final String id;

  final String name;

  /// Provider-native parent identifier (null if root).
  final String? parentId;

  /// MIME type string (e.g. 'image/jpeg', 'application/vnd.google-apps.folder').
  final String mimeType;

  final int? size;
  final DateTime? createdAt;
  final DateTime? modifiedAt;
  final bool isFolder;

  /// Direct web URL to view the file (null for local files).
  final String? webViewLink;

  /// URL of a small preview thumbnail (null for local files or unsupported types).
  final String? thumbnailLink;

  const FileSourceFile({
    required this.id,
    required this.name,
    this.parentId,
    required this.mimeType,
    this.size,
    this.createdAt,
    this.modifiedAt,
    required this.isFolder,
    this.webViewLink,
    this.thumbnailLink,
  });

  @override
  String toString() =>
      'FileSourceFile(id: $id, name: $name, isFolder: $isFolder, mimeType: $mimeType)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileSourceFile &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
