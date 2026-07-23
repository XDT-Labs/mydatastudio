import 'dart:async';
import 'dart:typed_data';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/services/credential_codec.dart';

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

  /// Upserts the Qwen3-VL embedding for [fileId] into the `files_embeddings`
  /// table, storing values as a packed Float32 BLOB via `vector_as_f32()`.
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
          INSERT INTO files_embeddings (file_id, qwen3_vl_embedding)
          VALUES (?, vector_as_f32(?))
          ON CONFLICT(file_id) DO UPDATE SET
            qwen3_vl_embedding = excluded.qwen3_vl_embedding
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
          INSERT INTO files_embeddings (file_id, qwen3_vl_embedding)
          VALUES (?, ?)
          ON CONFLICT(file_id) DO UPDATE SET
            qwen3_vl_embedding = excluded.qwen3_vl_embedding
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
        'qwen3_vl_embedding',
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

  /// Fetches the Qwen3-VL embedding for [fileId].
  /// Returns null if no embedding exists for this file.
  Future<List<double>?> getFileEmbedding(String fileId) async {
    final rows = await db.select(
      'SELECT qwen3_vl_embedding FROM files_embeddings WHERE file_id = ? LIMIT 1',
      [fileId],
    );
    if (rows.isEmpty || rows.first['qwen3_vl_embedding'] == null) return null;
    final blob = rows.first['qwen3_vl_embedding'] as Uint8List;
    return Float32List.view(blob.buffer).toList();
  }

  /// Returns files visually similar to [queryEmbedding] using the Qwen3-VL index.
  /// [excludeFileId] removes the source file from results.
  /// Similarity is (1 − L2distance/2)×100 assuming L2-normalised unit vectors.
  Future<List<({File file, double similarity})>> findSimilarImages(
    List<double> queryEmbedding, {
    String? excludeFileId,
    int limit = 100,
  }) async {
    final jsonArray = '[${queryEmbedding.join(',')}]';
    final excludeClause = excludeFileId != null ? 'AND e.file_id != ?' : '';
    final params = [jsonArray, limit, if (excludeFileId != null) excludeFileId];

    final rows = await db.select(
      '''
      SELECT f.*, v.distance
      FROM files_embeddings AS e
      JOIN files AS f ON f.id = e.file_id
      JOIN vector_full_scan(
        'files_embeddings',
        'qwen3_vl_embedding',
        vector_as_f32(?),
        ?
      ) AS v ON e.rowid = v.rowid
      WHERE f.is_deleted = 0
        $excludeClause
      ORDER BY v.distance ASC
      ''',
      params,
    );

    return rows.map((row) {
      final distance = (row['distance'] as num).toDouble();
      final similarity = ((1.0 - distance / 2.0) * 100).clamp(0.0, 100.0);
      return (file: File.fromDbMap(row), similarity: similarity);
    }).toList();
  }

  /// Returns a list of files that do not have a corresponding entry in the
  /// `files_embeddings` table, limited to [limit] results.
  /// Filters for image content types.
  Future<List<File>> getFilesWithMissingEmbeddings({int limit = 10}) async {
    final rows = await db.select(
      '''
      SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner
      FROM files f
      LEFT OUTER JOIN files_embeddings fe ON fe.file_id = f.id
      INNER JOIN collections c ON c.id = f.collection_id
      WHERE (fe.file_id IS NULL OR fe.qwen3_vl_embedding IS NULL)
        AND (f.content_type = 'application/image' OR f.content_type LIKE 'image/%')
        AND f.is_deleted = 0
      LIMIT ?
      ''',
      [limit],
    );
    var results = rows.map((row) {
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
    }).toList();
    return results;
  }

  Future<Collection?> getCollection(String id) async {
    final rows = await db.select(
      "SELECT * FROM collections WHERE id = ? LIMIT 1",
      [id],
    );
    if (rows.isEmpty) return null;
    // Decrypt OAuth tokens so the returned model holds plaintext. This runs
    // inside worker isolates, where the DEK must have been installed at isolate
    // entry (AUDIT M2 phase 3/4); a locked codec fails loudly rather than
    // handing back ciphertext.
    final c = Collection.fromDbMap(rows.first);
    c.accessToken = CredentialCodec.decrypt(c.accessToken);
    c.refreshToken = CredentialCodec.decrypt(c.refreshToken);
    c.idToken = CredentialCodec.decrypt(c.idToken);
    return c;
  }
}
