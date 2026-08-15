import 'dart:async';
import 'dart:typed_data';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
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
  /// Writes only when the `files` row still exists. The embedding isolates run
  /// independently of deletion, so a file or collection deleted while its
  /// embedding is in flight would otherwise write back against a row that is
  /// gone and fail the foreign key — surfacing as a spurious error mid-scan,
  /// and misreported by the fallback below as a missing vector extension.
  /// A vanished file is a no-op, not a failure.
  ///
  /// The `vector_as_f32()` call is skipped gracefully when the sqlite_vector
  /// extension is not loaded (dev/test builds without native assets).
  ///
  /// [type] distinguishes what the embedding was computed from — 'file' (the
  /// default) for the image itself, 'description' for a generated caption's
  /// text. Both share this table and column, keyed on (file_id, type), so a
  /// file can carry one row per kind without either overwriting the other.
  Future<void> upsertFileEmbedding(
    String fileId,
    List<double> embedding, {
    String type = 'file',
  }) async {
    // Build JSON array string that sqlite_vector's vector_as_f32() accepts.
    final jsonArray = '[${embedding.join(',')}]';

    int affectedRows = 0;
    await db.transaction((tx) async {
      try {
        // Use vector_as_f32() to pack the JSON float array into a BLOB.
        final result = await tx.execute(
          '''
          INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding)
          SELECT ?, ?, vector_as_f32(?)
          WHERE EXISTS (SELECT 1 FROM files WHERE id = ?)
          ON CONFLICT(file_id, type) DO UPDATE SET
            qwen3_vl_embedding = excluded.qwen3_vl_embedding
          ''',
          [fileId, type, jsonArray, fileId],
        );
        affectedRows = result.affectedRows;
      } catch (e) {
        // Fallback: store as raw Float32 BLOB when extension is not loaded
        // (e.g. unit tests). The BLOB can still be read back; vector_full_scan
        // won't work, but upsert/delete operations succeed.
        logger.w('vector_as_f32 unavailable, storing raw BLOB: $e');
        final blob = Float32List.fromList(embedding).buffer.asUint8List();
        final result = await tx.execute(
          '''
          INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding)
          SELECT ?, ?, ?
          WHERE EXISTS (SELECT 1 FROM files WHERE id = ?)
          ON CONFLICT(file_id, type) DO UPDATE SET
            qwen3_vl_embedding = excluded.qwen3_vl_embedding
          ''',
          [fileId, type, blob, fileId],
        );
        affectedRows = result.affectedRows;
      }
    });

    // The WHERE EXISTS guard makes a missing `files` row a silent no-op
    // (0 rows affected, no exception) rather than a failure — surface it
    // loudly instead of letting the caller believe the embedding was saved.
    if (affectedRows == 0) {
      logger.w(
        'upsertFileEmbedding: no row written for fileId=$fileId type=$type '
        '— files row missing or not yet visible to this connection',
      );
    } else {
      logger.d(
        'upsertFileEmbedding: fileId=$fileId type=$type dim=${embedding.length}',
      );
    }
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

    // vector_full_scan computes distance against every row regardless of the
    // requested count — it's a brute-force scan, not an index — so asking it
    // for more than [limit] costs nothing extra. That headroom is what lets
    // the type filter below happen after the scan without under-filling the
    // result: a file with both a 'file' and a 'description' embedding row
    // could otherwise place its own duplicate ahead of a genuinely different
    // file's row within the scan's raw top-N.
    final rows = await db.select(
      '''
      SELECT file_id, distance FROM (
        SELECT e.file_id, e.type, v.distance
        FROM files_embeddings AS e
        JOIN vector_full_scan(
          'files_embeddings',
          'qwen3_vl_embedding',
          vector_as_f32(?),
          ?
        ) AS v ON e.rowid = v.rowid
      )
      WHERE type = 'file'
      ORDER BY distance ASC
      LIMIT ?
      ''',
      [jsonArray, limit * 5, limit],
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

  /// Fetches the [type] embedding for [fileId] ('file' by default — the
  /// image itself, as opposed to a 'description' text embedding).
  /// Returns null if no embedding exists for this file/type.
  Future<List<double>?> getFileEmbedding(
    String fileId, {
    String type = 'file',
  }) async {
    final rows = await db.select(
      'SELECT qwen3_vl_embedding FROM files_embeddings WHERE file_id = ? AND type = ? LIMIT 1',
      [fileId, type],
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
    final params = [
      jsonArray,
      // See findSimilarFiles: over-fetch from the full scan so filtering to
      // type='file' afterward can't leave fewer than [limit] real matches.
      limit * 5,
      if (excludeFileId != null) excludeFileId,
      limit,
    ];

    final rows = await db.select('''
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
        AND f.is_user_deleted = 0
        AND e.type = 'file'
        $excludeClause
      ORDER BY v.distance ASC
      LIMIT ?
      ''', params);

    return rows.map((row) {
      final distance = (row['distance'] as num).toDouble();
      final similarity = ((1.0 - distance / 2.0) * 100).clamp(0.0, 100.0);
      return (file: File.fromDbMap(row), similarity: similarity);
    }).toList();
  }

  /// Returns a list of files that do not have a corresponding entry in the
  /// `files_embeddings` table, limited to [limit] results.
  /// Filters for image content types.
  ///
  /// Images the message body embeds — spacers, logos, tracking pixels, ad
  /// banners — are skipped. Embedding them costs real on-device inference time
  /// per image and buys nothing: they are only ever looked at inside the email
  /// they decorate, and an HTML newsletter carries a dozen apiece. Worse, they
  /// then pollute similarity search. See `InlineAttachment`.
  /// Give up on a file after this many failures caused by the file itself.
  ///
  /// Only permanent failures count — see [incrementEmbeddingAttempts] — so this
  /// is a guard against unreadable files, not against an aiserver outage.
  static const maxEmbeddingAttempts = 5;

  Future<List<File>> getFilesWithMissingEmbeddings({int limit = 10}) async {
    final rows = await db.select(
      '''
      SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner
      FROM files f
      LEFT OUTER JOIN files_embeddings fe
        ON fe.file_id = f.id AND fe.type = 'file'
      INNER JOIN collections c ON c.id = f.collection_id
      WHERE (fe.file_id IS NULL OR fe.qwen3_vl_embedding IS NULL)
        AND (f.content_type = 'application/image' OR f.content_type LIKE 'image/%')
        AND f.is_deleted = 0
        AND f.is_user_deleted = 0
        AND f.is_inline = 0
        AND f.embedding_attempts < ?
      LIMIT ?
      ''',
      [maxEmbeddingAttempts, limit],
    );
    return _filesWithResolvedPaths(rows);
  }

  /// Files that have failed description generation this many times are
  /// excluded from [getFilesWithMissingDescriptions] — past this point the
  /// failure is treated as permanent (unreadable image, unsupported format)
  /// rather than worth retrying every batch forever.
  static const maxDescriptionAttempts = 5;

  /// Returns images with no AI-generated description yet, limited to
  /// [limit] results. Same eligibility rules as
  /// [getFilesWithMissingEmbeddings] (real images, not deleted, not an
  /// inline message-body asset), plus excluding files that have already
  /// exhausted [maxDescriptionAttempts].
  Future<List<File>> getFilesWithMissingDescriptions({int limit = 10}) async {
    final rows = await db.select(
      '''
      SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner
      FROM files f
      INNER JOIN collections c ON c.id = f.collection_id
      WHERE f.description IS NULL
        AND (f.content_type = 'application/image' OR f.content_type LIKE 'image/%')
        AND f.is_deleted = 0
        AND f.is_user_deleted = 0
        AND f.is_inline = 0
        AND f.description_attempts < ?
      LIMIT ?
      ''',
      [maxDescriptionAttempts, limit],
    );
    return _filesWithResolvedPaths(rows);
  }

  /// Records a failed embedding attempt for [fileId] so
  /// [getFilesWithMissingEmbeddings] eventually stops re-selecting a file that
  /// can never succeed.
  ///
  /// Only for failures the file itself causes — an unreadable or non-image
  /// payload, a path that has gone. A failure that says nothing about the file,
  /// such as the aiserver being down, must not count: it would spend the budget
  /// on every photo in the library during a single outage and permanently
  /// exclude them all.
  Future<void> incrementEmbeddingAttempts(String fileId) async {
    await db.execute(
      'UPDATE files SET embedding_attempts = embedding_attempts + 1 '
      'WHERE id = ?',
      [fileId],
    );
  }

  /// Records a failed description-generation attempt for [fileId] so
  /// [getFilesWithMissingDescriptions] eventually stops re-selecting a file
  /// that can never succeed.
  Future<void> incrementDescriptionAttempts(String fileId) async {
    await db.execute(
      'UPDATE files SET description_attempts = description_attempts + 1 '
      'WHERE id = ?',
      [fileId],
    );
  }

  /// Builds [File] models from a `files` query joined with `collections` as
  /// `col_path`/`local_copy_path`/`scanner`, resolving each file's absolute
  /// path against a throwaway [Collection] built from those columns.
  List<File> _filesWithResolvedPaths(List<Map<String, Object?>> rows) {
    return rows.map((row) {
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
  }

  /// Persists Gemma's analysis of [fileId]'s image: the generated
  /// [description] onto `files`, [tags] and [landmarks] into their join
  /// tables, and the description's own text [embedding] into
  /// `files_embeddings` as a 'description'-type row (see [upsertFileEmbedding]
  /// for why 'file' and 'description' can coexist per file).
  ///
  /// All in one transaction so a file never ends up with a description but
  /// no tags, or tags but no embedding, if something fails partway through.
  Future<void> saveFileDescription(
    String fileId, {
    required String description,
    required List<String> tags,
    required List<String> landmarks,
    required List<double> embedding,
  }) async {
    final jsonArray = '[${embedding.join(',')}]';

    try {
      await db.transaction((tx) async {
        final updated = await tx.execute(
          'UPDATE files SET description = ? WHERE id = ?',
          [description, fileId],
        );
        if (updated.affectedRows == 0) {
          // File vanished before analysis finished — nothing left to attach
          // tags/landmarks/embedding to inside this same transaction.
          logger.w(
            'saveFileDescription: fileId=$fileId not found, dropping analysis',
          );
          return;
        }

        for (final tag in tags) {
          await tx.execute(
            'INSERT OR IGNORE INTO file_tags (file_id, tag) VALUES (?, ?)',
            [fileId, tag],
          );
        }
        for (final landmark in landmarks) {
          await tx.execute(
            'INSERT OR IGNORE INTO file_landmarks (file_id, landmark) VALUES (?, ?)',
            [fileId, landmark],
          );
        }

        try {
          await tx.execute(
            '''
            INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding)
            VALUES (?, 'description', vector_as_f32(?))
            ON CONFLICT(file_id, type) DO UPDATE SET
              qwen3_vl_embedding = excluded.qwen3_vl_embedding
            ''',
            [fileId, jsonArray],
          );
        } catch (e) {
          logger.w('vector_as_f32 unavailable, storing raw BLOB: $e');
          final blob = Float32List.fromList(embedding).buffer.asUint8List();
          await tx.execute(
            '''
            INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding)
            VALUES (?, 'description', ?)
            ON CONFLICT(file_id, type) DO UPDATE SET
              qwen3_vl_embedding = excluded.qwen3_vl_embedding
            ''',
            [fileId, blob],
          );
        }
      });
      logger.d('saveFileDescription: fileId=$fileId saved');
    } catch (e, stackTrace) {
      logger.e(
        'saveFileDescription: failed for fileId=$fileId: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Returns [fileId]'s tags, alphabetically.
  Future<List<String>> getFileTags(String fileId) async {
    final rows = await db.select(
      'SELECT tag FROM file_tags WHERE file_id = ? ORDER BY tag',
      [fileId],
    );
    return rows.map((r) => r['tag'] as String).toList();
  }

  /// Returns [fileId]'s landmarks, alphabetically.
  Future<List<String>> getFileLandmarks(String fileId) async {
    final rows = await db.select(
      'SELECT landmark FROM file_landmarks WHERE file_id = ? ORDER BY landmark',
      [fileId],
    );
    return rows.map((r) => r['landmark'] as String).toList();
  }

  /// Adds a single manually-entered [tag] to [fileId]. A no-op if the tag
  /// is already present (case-sensitive — the UI is responsible for
  /// case-insensitive dedup against the tags it already has loaded).
  Future<void> addFileTag(String fileId, String tag) async {
    await db.execute(
      'INSERT OR IGNORE INTO file_tags (file_id, tag) VALUES (?, ?)',
      [fileId, tag],
    );
  }

  /// Removes a single [tag] from [fileId] (e.g. the user dismissing a pill
  /// in the UI). A no-op if the tag isn't present.
  Future<void> deleteFileTag(String fileId, String tag) async {
    await db.execute('DELETE FROM file_tags WHERE file_id = ? AND tag = ?', [
      fileId,
      tag,
    ]);
  }

  /// Removes a single [landmark] from [fileId]. A no-op if not present.
  Future<void> deleteFileLandmark(String fileId, String landmark) async {
    await db.execute(
      'DELETE FROM file_landmarks WHERE file_id = ? AND landmark = ?',
      [fileId, landmark],
    );
  }

  // ---------------------------------------------------------------------------
  // Email Embedding Methods (sqlite_vector API)
  // ---------------------------------------------------------------------------

  /// Upserts the Qwen3-VL embedding for [emailId] into the `emails_embeddings`
  /// table, storing values as a packed Float32 BLOB via `vector_as_f32()`.
  ///
  /// Guarded on the `emails` row still existing, for the same reason as
  /// [upsertFileEmbedding].
  Future<void> upsertEmailEmbedding(
    String emailId,
    List<double> embedding,
  ) async {
    final jsonArray = '[${embedding.join(',')}]';

    int affectedRows = 0;
    await db.transaction((tx) async {
      try {
        final result = await tx.execute(
          '''
          INSERT INTO emails_embeddings (email_id, qwen3_vl_embedding)
          SELECT ?, vector_as_f32(?)
          WHERE EXISTS (SELECT 1 FROM emails WHERE id = ?)
          ON CONFLICT(email_id) DO UPDATE SET
            qwen3_vl_embedding = excluded.qwen3_vl_embedding
          ''',
          [emailId, jsonArray, emailId],
        );
        affectedRows = result.affectedRows;
      } catch (e) {
        logger.w('vector_as_f32 unavailable, storing raw BLOB: $e');
        final blob = Float32List.fromList(embedding).buffer.asUint8List();
        final result = await tx.execute(
          '''
          INSERT INTO emails_embeddings (email_id, qwen3_vl_embedding)
          SELECT ?, ?
          WHERE EXISTS (SELECT 1 FROM emails WHERE id = ?)
          ON CONFLICT(email_id) DO UPDATE SET
            qwen3_vl_embedding = excluded.qwen3_vl_embedding
          ''',
          [emailId, blob, emailId],
        );
        affectedRows = result.affectedRows;
      }
    });

    // See upsertFileEmbedding: WHERE EXISTS makes a missing `emails` row a
    // silent no-op rather than a failure — surface it loudly.
    if (affectedRows == 0) {
      logger.w(
        'upsertEmailEmbedding: no row written for emailId=$emailId — '
        'emails row missing or not yet visible to this connection',
      );
    } else {
      logger.d(
        'upsertEmailEmbedding: emailId=$emailId dim=${embedding.length}',
      );
    }
  }

  /// Deletes the embedding record for [emailId] from `emails_embeddings`.
  Future<void> deleteEmailEmbedding(String emailId) async {
    await db.transaction((tx) async {
      await tx.execute('DELETE FROM emails_embeddings WHERE email_id = ?', [
        emailId,
      ]);
    });
    logger.d('deleteEmailEmbedding: emailId=$emailId');
  }

  /// Fetches the Qwen3-VL embedding for [emailId].
  /// Returns null if no embedding exists for this email.
  Future<List<double>?> getEmailEmbedding(String emailId) async {
    final rows = await db.select(
      'SELECT qwen3_vl_embedding FROM emails_embeddings WHERE email_id = ? LIMIT 1',
      [emailId],
    );
    if (rows.isEmpty || rows.first['qwen3_vl_embedding'] == null) return null;
    final blob = rows.first['qwen3_vl_embedding'] as Uint8List;
    return Float32List.view(blob.buffer).toList();
  }

  /// Returns a list of emails that do not have a corresponding entry in the
  /// `emails_embeddings` table, limited to [limit] results.
  ///
  /// Excludes `headers` — the raw MIME header dump, unused by
  /// `formatEmailForEmbedding` and easily the largest column on a row. The
  /// embedding isolate pulls batches of up to 1000; carrying that column
  /// along would materialize its full size for every one of them for no
  /// benefit. `Email.fromDbMap` leaves `headers` null when the key is
  /// absent, which is fine here since these rows are never written back.
  Future<List<Email>> getEmailsWithMissingEmbeddings({int limit = 10}) async {
    final rows = await db.select(
      '''
      SELECT e.id, e.collection_id, e.date, e."from", e."to", e.cc,
             e.subject, e.snippet, e.html_body, e.plain_body, e.labels,
             e.folder_id, e.message_id, e.thread_id, e.is_read,
             e.has_attachments, e.is_deleted, e.uid
      FROM emails e
      LEFT OUTER JOIN emails_embeddings ee ON ee.email_id = e.id
      WHERE (ee.email_id IS NULL OR ee.qwen3_vl_embedding IS NULL)
        AND e.is_deleted = 0
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map((row) => Email.fromDbMap(row)).toList();
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
