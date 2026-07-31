import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';

import 'package:intl/intl.dart';

class PhotosRepository {
  AppLogger logger = AppLogger(null);

  /// Attachments that are part of an email's own presentation — spacers,
  /// logos, tracking pixels, ad banners — are excluded here. They are images by
  /// content type and are attached to the message like any other file, so
  /// without this filter a single HTML newsletter drops a dozen of them into
  /// the photo grid. See `InlineAttachment`.
  static const String _excludeInline = " AND f.is_inline = 0";

  /// Both spellings of "this is an image" have to be matched.
  ///
  /// Gmail is the only scanner that records the real MIME type on the row
  /// (`image/jpeg`); the local, Drive, Yahoo, Outlook and PST scanners all
  /// store the app's coarse category (`application/image`). Matching the
  /// category alone — which is what this did — silently kept every Gmail image
  /// attachment out of the grid, whether or not it had a thumbnail. Mirrors the
  /// filter `getFilesWithMissingEmbeddings` already uses, so the photo grid and
  /// the embedding queue agree on what counts as a picture.
  static const String _isImage =
      " (f.content_type = ? OR f.content_type LIKE 'image/%')";

  Future<List<File>> photos() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    final rows = await db.select(
      "SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner"
      " FROM files f"
      " JOIN collections c ON f.collection_id = c.id"
      " WHERE$_isImage$_excludeInline"
      " ORDER BY f.date_created DESC",
      [FilesConstants.mimeTypeImage],
    );
    return rows.map((r) => _fileWithAbsolutePath(r)).toList();
  }

  Future<Map<String, List<File>>> photosByDate() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return {};
    DateFormat dateFormat = DateFormat("yyyy-MM-dd");
    Map<String, List<File>> groupedImages = {};

    final rows = await db.select(
      "SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner"
      " FROM files f"
      " JOIN collections c ON f.collection_id = c.id"
      " WHERE$_isImage$_excludeInline"
      " ORDER BY f.date_created ASC",
      [FilesConstants.mimeTypeImage],
    );

    for (var r in rows) {
      final f = _fileWithAbsolutePath(r);
      final group = dateFormat.format(f.dateCreated);
      groupedImages.putIfAbsent(group, () => []).add(f);
    }

    return groupedImages;
  }

  File _fileWithAbsolutePath(Map<String, dynamic> row) {
    final file = File.fromDbMap(row);
    final fakeCollection = Collection(
      id: file.collectionId,
      name: '',
      path: (row['col_path'] as String?) ?? '',
      type: '',
      scanner: (row['scanner'] as String?) ?? '',
      scanStatus: '',
      needsReAuth: false,
      localCopyPath: row['local_copy_path'] as String?,
    );
    file.path = FilePathResolver.absolute(file, fakeCollection);
    return file;
  }
}
