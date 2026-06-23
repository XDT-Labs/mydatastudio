import 'dart:io' as io;

import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/file_sources/file_source_file.dart';
import 'package:mydatastudio/file_sources/file_source_provider.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

/// [FileSourceProvider] implementation for local filesystem collections.
///
/// This class is the UI-actions companion to [LocalFileIsolate]. It does NOT
/// perform background scanning — that remains the responsibility of the
/// existing isolate. This class only handles on-demand UI operations:
/// listing a folder's contents, downloading (a no-op for local files),
/// deleting from disk, and opening in the system viewer.
class LocalFileProvider implements FileSourceProvider {
  const LocalFileProvider();

  @override
  String get providerKey => 'local';

  @override
  String get scannerType => AppConstants.scannerFileLocal;

  @override
  String get displayName => 'Local Files';

  // ---------------------------------------------------------------------------
  // Browse
  // ---------------------------------------------------------------------------

  @override
  Future<List<FileSourceFile>> listFolder(
    Collection collection, {
    String? folderId,
  }) async {
    final dirPath = folderId ?? collection.path;
    final dir = io.Directory(dirPath);

    if (!dir.existsSync()) return [];

    final List<FileSourceFile> results = [];
    try {
      for (final entity in dir.listSync(recursive: false, followLinks: false)) {
        final stat = entity.statSync();
        final name = p.basename(entity.path);

        // Skip hidden files/folders
        if (name.startsWith('.')) continue;

        results.add(
          FileSourceFile(
            id: entity.path,
            name: name,
            parentId: dirPath,
            mimeType:
                entity is io.Directory
                    ? 'inode/directory'
                    : _mimeTypeFromName(name),
            size: entity is io.File ? stat.size : null,
            createdAt:
                stat.modified, // dart:io has no createdAt on all platforms
            modifiedAt: stat.modified,
            isFolder: entity is io.Directory,
          ),
        );
      }
    } catch (e) {
      // Permission denied or path gone — return what we have
    }

    return results;
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// For local files, "download" means the file is already on disk.
  /// If [destPath] differs from the source, a copy is made.
  /// Otherwise the original file handle is returned.
  @override
  Future<io.File> downloadFile(
    Collection collection,
    FileSourceFile file,
    String destPath,
  ) async {
    final source = io.File(file.id);
    if (file.id == destPath) return source;
    return source.copy(destPath);
  }

  /// Deletes the file from disk permanently.
  @override
  Future<bool> deleteFile(Collection collection, FileSourceFile file) async {
    try {
      final f = io.File(file.id);
      if (await f.exists()) {
        await f.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the file with the system default application via [OpenFilex].
  @override
  Future<void> openFile(Collection collection, FileSourceFile file) async {
    await OpenFilex.open(file.id);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  String _mimeTypeFromName(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    const map = <String, String>{
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'tif': 'image/tiff',
      'tiff': 'image/tiff',
      'psd': 'image/vnd.adobe.photoshop',
      'pdf': 'application/pdf',
      'mp4': 'video/mp4',
      'm4v': 'video/x-m4v',
      'mov': 'video/quicktime',
      'mpeg': 'video/mpeg',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain',
      'html': 'text/html',
      'htm': 'text/html',
      'xml': 'text/xml',
      'zip': 'application/zip',
    };
    return map[ext] ?? 'application/octet-stream';
  }
}
