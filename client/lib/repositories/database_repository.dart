import 'dart:async';
import 'dart:typed_data';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';

class DatabaseRepository {
  AppDatabase db;
  final AppLogger logger = AppLogger(null);

  DatabaseRepository(this.db);

  Future<int> countAllRows(String table) async {
    final rows = await db.select("select count(*) as count from $table;");
    if (rows.isEmpty) return 0;
    return rows.first['count'] as int;
  }

  // ---------------------------------------------------------------------------
  // Embedding Methods (sqlite_vector API)
  // ---------------------------------------------------------------------------

  /// Upserts the Qwen3-8B embedding for [fileId] into the `files_embeddings`
  /// table, storing values as a packed Float32 BLOB via `vector_as_f32()`.
  ///
  /// [embedding] must be 2048 elements (Qwen3-8B output dimensionality).
  ///
  /// The `vector_as_f32()` call is skipped gracefully when the sqlite_vector
  /// extension is not loaded (dev/test builds without native assets).
  Future<void> upsertFileEmbedding(
    String fileId,
    List<double> embedding,
  ) async {
    // Build JSON array string that sqlite_vector's vector_as_f32() accepts.
    final jsonArray = '[${embedding.join(',')}]';

    await db.transaction((tx) async {
      try {
        // Use vector_as_f32() to pack the JSON float array into a BLOB.
        await tx.execute(
          '''
          INSERT INTO files_embeddings (file_id, qwen3_8b_embedding)
          VALUES (?, vector_as_f32(?))
          ON CONFLICT(file_id) DO UPDATE SET
            qwen3_8b_embedding = excluded.qwen3_8b_embedding
          ''',
          [fileId, jsonArray],
        );
      } catch (e) {
        // Fallback: store as raw Float32 BLOB when extension is not loaded
        // (e.g. unit tests). The BLOB can still be read back; vector_full_scan
        // won't work, but upsert/delete operations succeed.
        logger.w('vector_as_f32 unavailable, storing raw BLOB: $e');
        final blob = Float32List.fromList(embedding).buffer.asUint8List();
        await tx.execute(
          '''
          INSERT INTO files_embeddings (file_id, qwen3_8b_embedding)
          VALUES (?, ?)
          ON CONFLICT(file_id) DO UPDATE SET
            qwen3_8b_embedding = excluded.qwen3_8b_embedding
          ''',
          [fileId, blob],
        );
      }
    });

    logger.d('upsertFileEmbedding: fileId=$fileId dim=${embedding.length}');
  }

  /// Deletes the embedding record for [fileId] from `files_embeddings`.
  ///
  /// Should be called when the corresponding file is permanently deleted.
  Future<void> deleteFileEmbedding(String fileId) async {
    await db.transaction((tx) async {
      await tx.execute('DELETE FROM files_embeddings WHERE file_id = ?', [
        fileId,
      ]);
    });
    logger.d('deleteFileEmbedding: fileId=$fileId');
  }

  /// Returns the [limit] most similar files to [queryEmbedding] using the
  /// sqlite_vector ANN index (smallest distance = most similar).
  ///
  /// Uses `vector_full_scan()` with the `vector_as_f32()` helper.
  /// [queryEmbedding] must be 2048-dimensional.
  ///
  /// Throws when the sqlite_vector extension is not loaded.
  Future<List<({String fileId, double distance})>> findSimilarFiles(
    List<double> queryEmbedding, {
    int limit = 20,
  }) async {
    final jsonArray = '[${queryEmbedding.join(',')}]';

    final rows = await db.select(
      '''
      SELECT e.file_id, v.distance
      FROM files_embeddings AS e
      JOIN vector_full_scan(
        'files_embeddings',
        'qwen3_8b_embedding',
        vector_as_f32(?),
        ?
      ) AS v ON e.rowid = v.rowid
      ORDER BY v.distance ASC
      ''',
      [jsonArray, limit],
    );

    return rows
        .map(
          (row) => (
            fileId: row['file_id'] as String,
            distance: (row['distance'] as num).toDouble(),
          ),
        )
        .toList();
  }

  /// Returns a list of files that do not have a corresponding entry in the
  /// `files_embeddings` table, limited to [limit] results.
  /// Filters for image content types.
  Future<List<File>> getFilesWithMissingEmbeddings({int limit = 10}) async {
    final rows = await db.select(
      '''
      SELECT f.*
      FROM files f
      LEFT OUTER JOIN files_embeddings fe ON fe.file_id = f.id
      INNER JOIN collections c ON c.id = f.collection_id
      WHERE fe.file_id IS NULL
        AND f.content_type LIKE 'image/%'
        AND f.is_deleted = 0
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map((row) => File.fromDbMap(row)).toList();
  }

  Future<Collection?> getCollection(String id) async {
    final rows = await db.select(
      "SELECT * FROM collections WHERE id = ? LIMIT 1",
      [id],
    );
    if (rows.isEmpty) return null;
    return Collection.fromDbMap(rows.first);
  }
}
