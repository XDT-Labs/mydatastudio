import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';

import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

class PhotosRepository {
  AppLogger logger = AppLogger(null);

  static const String _excludeInline = " AND f.is_inline = 0";
  static const String _excludeDeleted = " AND f.is_deleted = 0";

  static const String _isImage = " (f.content_type = ? OR f.content_type LIKE 'image/%')";
  static const String _isVideo = " (f.content_type LIKE 'video/%')";
  static const String _isMedia = " ($_isImage OR $_isVideo)";

  String _buildFilterQuery(PhotoFilter? filter, List<Object?> params) {
    String q = _excludeInline + _excludeDeleted;
    
    if (filter == null) {
      q += " AND $_isMedia";
      params.add(FilesConstants.mimeTypeImage);
      return q;
    }

    if (filter.mediaType == 'photo') {
      q += " AND $_isImage";
      params.add(FilesConstants.mimeTypeImage);
    } else if (filter.mediaType == 'video') {
      q += " AND $_isVideo";
    } else {
      q += " AND $_isMedia";
      params.add(FilesConstants.mimeTypeImage);
    }

    if (filter.searchQuery.isNotEmpty) {
      q += " AND (f.name LIKE ? OR f.path LIKE ? OR f.id IN (SELECT file_id FROM file_tags WHERE tag LIKE ?) OR f.id IN (SELECT file_id FROM file_landmarks WHERE landmark LIKE ?))";
      final searchPattern = '%${filter.searchQuery}%';
      params.addAll([searchPattern, searchPattern, searchPattern, searchPattern]);
    }

    if (filter.source != null) {
      q += " AND c.type = ?";
      params.add(filter.source);
    }

    if (filter.albumId != null) {
      q += " AND f.id IN (SELECT file_id FROM album_files WHERE album_id = ?)";
      params.add(filter.albumId);
    }

    if (filter.tag != null) {
      q += " AND f.id IN (SELECT file_id FROM file_tags WHERE tag = ?)";
      params.add(filter.tag);
    }

    if (filter.location != null) {
      q += " AND f.id IN (SELECT file_id FROM file_landmarks WHERE landmark = ?)";
      params.add(filter.location);
    }

    if (filter.onlyFavorites) {
      q += " AND f.is_favorite = 1";
    }

    return q;
  }

  String _buildSortQuery(PhotoFilter? filter) {
    if (filter == null) return " ORDER BY f.date_created DESC";
    
    switch (filter.sortBy) {
      case PhotoSortOrder.dateAsc:
        return " ORDER BY f.date_created ASC";
      case PhotoSortOrder.title:
        return " ORDER BY f.name ASC";
      case PhotoSortOrder.size:
        return " ORDER BY f.size DESC";
      case PhotoSortOrder.dateDesc:
      default:
        return " ORDER BY f.date_created DESC";
    }
  }

  Future<List<File>> photos({PhotoFilter? filter}) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    List<Object?> params = [];
    String query = "SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner"
                   " FROM files f"
                   " JOIN collections c ON f.collection_id = c.id"
                   " WHERE 1=1 " + _buildFilterQuery(filter, params) + _buildSortQuery(filter);

    final rows = await db.select(query, params);
    return rows.map((r) => _fileWithAbsolutePath(r)).toList();
  }

  Future<Map<String, List<File>>> photosByDate({PhotoFilter? filter}) async {
    final list = await photos(filter: filter?.copyWith(sortBy: PhotoSortOrder.dateAsc));
    DateFormat dateFormat = DateFormat("yyyy-MM-dd");
    Map<String, List<File>> grouped = {};

    for (var f in list) {
      final group = dateFormat.format(f.dateCreated);
      grouped.putIfAbsent(group, () => []).add(f);
    }
    return grouped;
  }

  Future<Map<String, List<File>>> photosByMonth({PhotoFilter? filter}) async {
    final list = await photos(filter: filter?.copyWith(sortBy: PhotoSortOrder.dateAsc));
    DateFormat dateFormat = DateFormat("yyyy-MM");
    Map<String, List<File>> grouped = {};

    for (var f in list) {
      final group = dateFormat.format(f.dateCreated);
      grouped.putIfAbsent(group, () => []).add(f);
    }
    return grouped;
  }

  Future<List<File>> photosWithLocation({PhotoFilter? filter}) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    List<Object?> params = [];
    String query = "SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner"
                   " FROM files f"
                   " JOIN collections c ON f.collection_id = c.id"
                   " WHERE f.latitude IS NOT NULL AND f.longitude IS NOT NULL " + _buildFilterQuery(filter, params) + _buildSortQuery(filter);

    final rows = await db.select(query, params);
    return rows.map((r) => _fileWithAbsolutePath(r)).toList();
  }

  Future<Map<String, int>> allTags() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return {};

    final rows = await db.select("SELECT tag, COUNT(*) as count FROM file_tags GROUP BY tag ORDER BY count DESC");
    Map<String, int> result = {};
    for (var r in rows) {
      result[r['tag'] as String] = r['count'] as int;
    }
    return result;
  }

  Future<Map<String, int>> allLocations() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return {};

    final rows = await db.select(
      "SELECT landmark, COUNT(*) as count FROM file_landmarks GROUP BY landmark ORDER BY count DESC",
    );
    Map<String, int> result = {};
    for (var r in rows) {
      result[r['landmark'] as String] = r['count'] as int;
    }
    return result;
  }

  Future<Map<String, int>> sourceCountsByType() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return {};

    final rows = await db.select('''
      SELECT c.type, COUNT(f.id) as count 
      FROM collections c 
      JOIN files f ON f.collection_id = c.id 
      WHERE 1=1 $_excludeInline $_excludeDeleted AND $_isMedia
      GROUP BY c.type
    ''', [FilesConstants.mimeTypeImage]);

    Map<String, int> result = {};
    for (var r in rows) {
      result[r['type'] as String] = r['count'] as int;
    }
    return result;
  }

  Future<void> toggleFavorite(String fileId) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    final rows = await db.select("SELECT is_favorite FROM files WHERE id = ?", [fileId]);
    if (rows.isNotEmpty) {
      int fav = (rows.first['is_favorite'] as int? ?? 0) == 1 ? 0 : 1;
      await db.execute("UPDATE files SET is_favorite = ? WHERE id = ?", [fav, fileId]);
    }
  }

  Future<void> addTag(String fileId, String tag) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    await db.execute("INSERT OR IGNORE INTO file_tags (file_id, tag) VALUES (?, ?)", [fileId, tag]);
  }

  Future<void> removeTag(String fileId, String tag) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    await db.execute("DELETE FROM file_tags WHERE file_id = ? AND tag = ?", [fileId, tag]);
  }

  Future<List<String>> getTagsForFile(String fileId) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    final rows = await db.select("SELECT tag FROM file_tags WHERE file_id = ?", [fileId]);
    return rows.map((r) => r['tag'] as String).toList();
  }

  Future<void> addFileToAlbum(String fileId, String albumId) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    await db.execute("INSERT OR IGNORE INTO album_files (album_id, file_id) VALUES (?, ?)", [albumId, fileId]);
  }

  Future<void> removeFileFromAlbum(String fileId, String albumId) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    await db.execute("DELETE FROM album_files WHERE file_id = ? AND album_id = ?", [fileId, albumId]);
  }

  Future<List<Album>> getAlbumsForFile(String fileId) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    final rows = await db.select('''
      SELECT a.* FROM albums a
      JOIN album_files af ON af.album_id = a.id
      WHERE af.file_id = ?
    ''', [fileId]);

    return rows.map((r) => Album.fromDbMap(r)).toList();
  }

  Future<void> createAlbum(Album album) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    final map = album.toDbMap();
    await db.execute(
      "INSERT INTO albums (id, name, description, cover_file_id) VALUES (?, ?, ?, ?)",
      [map['id'], map['name'], map['description'], map['cover_file_id']]
    );
  }

  Future<Album?> getAlbum(String albumId) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return null;

    final rows = await db.select("SELECT * FROM albums WHERE id = ?", [albumId]);
    if (rows.isEmpty) return null;
    return Album.fromDbMap(rows.first);
  }

  Future<void> updateAlbum(String albumId, String name, String? description) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    await db.execute("UPDATE albums SET name = ?, description = ? WHERE id = ?", [name, description, albumId]);
  }

  Future<void> deleteAlbum(String albumId) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    await db.execute("DELETE FROM albums WHERE id = ?", [albumId]);
  }

  Future<List<Album>> allAlbums() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    final rows = await db.select("SELECT * FROM albums ORDER BY name ASC");
    return rows.map((r) => Album.fromDbMap(r)).toList();
  }

  Future<List<({Album album, int count})>> allAlbumsWithCounts() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return [];

    final rows = await db.select('''
      SELECT a.*, COUNT(af.file_id) as count 
      FROM albums a
      LEFT JOIN album_files af ON af.album_id = a.id
      GROUP BY a.id
      ORDER BY a.name ASC
    ''');

    return rows.map((r) => (
      album: Album.fromDbMap(r),
      count: (r['count'] as int? ?? 0),
    )).toList();
  }

  Future<void> updateFileName(String fileId, String newName) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    await db.execute("UPDATE files SET name = ? WHERE id = ?", [newName, fileId]);
  }

  Future<void> deleteFile(String fileId) async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return;

    await db.execute("UPDATE files SET is_deleted = 1 WHERE id = ?", [fileId]);
  }

  Future<({int usedBytes, int totalBytes})> storageUsage() async {
    AppDatabase? db = DatabaseManager.instance.database;
    if (db == null) return (usedBytes: 0, totalBytes: 0);

    final rows = await db.select("SELECT SUM(f.size) as total_size FROM files f WHERE 1=1 $_excludeDeleted AND $_isMedia", [FilesConstants.mimeTypeImage]);
    int usedBytes = 0;
    if (rows.isNotEmpty) {
      usedBytes = rows.first['total_size'] as int? ?? 0;
    }
    int totalBytes = 1000 * 1024 * 1024 * 1024; // 1000 GB
    return (usedBytes: usedBytes, totalBytes: totalBytes);
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
