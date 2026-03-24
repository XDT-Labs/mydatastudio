import 'dart:async';
import 'dart:typed_data';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:drift/drift.dart';

class DatabaseRepository {
  AppDatabase db;
  final AppLogger logger = AppLogger(null);

  DatabaseRepository(this.db);

  ///
  /// Helper SQL Methods
  ///

  Future<int> countAllRows(String table) async {
    var rows = db.customSelect("select count(*) as count from $table;");
    return (await rows.getSingle()).read("count");
  }

  // ---------------------------------------------------------------------------
  // Embedding Methods (sqlite_vector API)
  // ---------------------------------------------------------------------------

  /// Upserts the Qwen3-8B embedding for [fileId] into the `files_embeddings`
  /// Drift table, storing values as a packed Float32 BLOB via `vector_as_f32()`.
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

    await db.transaction(() async {
      try {
        // Use vector_as_f32() to pack the JSON float array into a BLOB.
        await db.customInsert(
          '''
          INSERT INTO files_embeddings (file_id, qwen3_8b_embedding)
          VALUES (?, vector_as_f32(?))
          ON CONFLICT(file_id) DO UPDATE SET
            qwen3_8b_embedding = excluded.qwen3_8b_embedding
          ''',
          variables: [
            Variable.withString(fileId),
            Variable.withString(jsonArray),
          ],
        );
      } catch (e) {
        // Fallback: store as raw Float32 BLOB when extension is not loaded
        // (e.g. unit tests). The BLOB can still be read back; vector_full_scan
        // won't work, but upsert/delete operations succeed.
        logger.w('vector_as_f32 unavailable, storing raw BLOB: $e');
        final blob = Float32List.fromList(embedding).buffer.asUint8List();
        await db.customInsert(
          '''
          INSERT INTO files_embeddings (file_id, qwen3_8b_embedding)
          VALUES (?, ?)
          ON CONFLICT(file_id) DO UPDATE SET
            qwen3_8b_embedding = excluded.qwen3_8b_embedding
          ''',
          variables: [
            Variable.withString(fileId),
            Variable.withBlob(blob),
          ],
        );
      }
    });

    logger.d('upsertFileEmbedding: fileId=$fileId dim=${embedding.length}');
  }

  /// Deletes the embedding record for [fileId] from `files_embeddings`.
  ///
  /// Should be called when the corresponding file is permanently deleted.
  Future<void> deleteFileEmbedding(String fileId) async {
    await db.transaction(() async {
      await db.customStatement(
        'DELETE FROM files_embeddings WHERE file_id = ?',
        [fileId],
      );
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

    final rows = await db.customSelect(
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
      variables: [
        Variable.withString(jsonArray),
        Variable.withInt(limit),
      ],
    ).get();

    return rows
        .map(
          (row) => (
            fileId: row.read<String>('file_id'),
            distance: row.read<double>('distance'),
          ),
        )
        .toList();
  }

  /// Returns a list of files that do not have a corresponding entry in the
  /// `files_embeddings` table, limited to [limit] results.
  /// Filters for image content types.
  Future<List<File>> getFilesWithMissingEmbeddings({int limit = 10}) async {
    final query = db.select(db.files).join([
      leftOuterJoin(
        db.filesEmbeddings,
        db.filesEmbeddings.fileId.equalsExp(db.files.id),
      ),
      innerJoin(
        db.collections,
        db.collections.id.equalsExp(db.files.collectionId),
      ),
    ])
      ..where(
        db.filesEmbeddings.fileId.isNull() &
            db.files.contentType.like('image/%') &
            db.files.isDeleted.equals(false),
      )
      ..limit(limit);

    final rows = await query.get();
    return rows.map((row) => row.readTable(db.files)).toList();
  }

  Future<Collection?> getCollection(String id) async {
    return (db.select(db.collections)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }
}
