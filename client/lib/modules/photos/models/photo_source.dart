/// Where a photo came from, shown as a breadcrumb in the info sidebar.
///
/// A photo that arrived as an email attachment resolves to the message that
/// carried it — subject as the leaf, and [emailId] set so the sidebar can
/// offer a way back to that message. Everything else resolves to the file
/// itself.
class PhotoSource {
  const PhotoSource({
    required this.collectionName,
    required this.leaf,
    this.folder,
    this.emailId,
  });

  /// Name of the collection the photo belongs to.
  final String collectionName;

  /// Email folder name, or the file's folder path — null/empty at the root.
  final String? folder;

  /// Email subject, or `<filename>.<extension>`.
  final String leaf;

  /// Set only for email attachments; the message that carried this photo.
  final String? emailId;

  bool get isEmail => emailId != null;

  /// `<collection name>/<folder if in one>/<email subject | filename.ext>`
  String get path => [
    collectionName,
    if (folder != null && folder!.isNotEmpty) folder!,
    leaf,
  ].where((segment) => segment.isNotEmpty).join('/');
}
