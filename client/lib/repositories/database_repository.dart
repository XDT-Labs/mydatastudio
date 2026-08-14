import 'dart:async';
import 'dart:typed_data';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/services/embedding_model.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/file_chunk.dart';
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
          INSERT INTO files_embeddings
            (file_id, type, qwen3_vl_embedding, model_version)
          SELECT ?, ?, vector_as_f32(?), ?
          WHERE EXISTS (SELECT 1 FROM files WHERE id = ?)
          ON CONFLICT(file_id, type, sequence) DO UPDATE SET
            qwen3_vl_embedding = excluded.qwen3_vl_embedding,
            model_version = excluded.model_version
          ''',
          [fileId, type, jsonArray, EmbeddingModel.current, fileId],
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
          INSERT INTO files_embeddings
            (file_id, type, qwen3_vl_embedding, model_version)
          SELECT ?, ?, ?, ?
          WHERE EXISTS (SELECT 1 FROM files WHERE id = ?)
          ON CONFLICT(file_id, type, sequence) DO UPDATE SET
            qwen3_vl_embedding = excluded.qwen3_vl_embedding,
            model_version = excluded.model_version
          ''',
          [fileId, type, blob, EmbeddingModel.current, fileId],
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
      // Success clears the failure budget, and this is not tidiness. The
      // eligibility query re-selects a file when `model_version` moves on, so
      // a file that once exhausted [maxEmbeddingAttempts] and later succeeded
      // would be held back at the *next* revision bump by a count describing a
      // problem that no longer exists — and held back silently, since a stale
      // vector is a present vector. [maxDescriptionAttempts] needs no
      // equivalent: a written description is never re-derived.
      await db.execute(
        'UPDATE files SET embedding_attempts = 0 WHERE id = ?',
        [fileId],
      );
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

  /// Files whose AI description is fine but whose *description vector* was
  /// written by an older embedding pipeline.
  ///
  /// Needed because the two are regenerated by different work. A stale
  /// description vector cannot be reclaimed by
  /// [getFilesWithMissingDescriptions] — that selects on `description IS NULL`,
  /// and these files have a perfectly good description — so without this query
  /// they would keep their noise vectors forever. Which matters more than it
  /// sounds: measured against this archive, the description vector beats the
  /// image vector for a text query on 44 of 45 photos, so leaving these stale
  /// would leave the *stronger* half of image search broken.
  ///
  /// Only the text is re-embedded. The caption itself is unaffected by an
  /// embedding change and costs a vision-model pass to regenerate, against
  /// well under a second to re-embed.
  Future<List<({String fileId, String description})>>
  getFilesWithStaleDescriptionEmbeddings({int limit = 10}) async {
    final rows = await db.select(
      '''
      SELECT f.id, f.description
      FROM files f
      INNER JOIN files_embeddings fe
        ON fe.file_id = f.id AND fe.type = 'description'
      WHERE f.description IS NOT NULL AND f.description <> ''
        AND f.is_deleted = 0
        AND IFNULL(fe.model_version, '') <> ?
      LIMIT ?
      ''',
      [EmbeddingModel.current, limit],
    );
    return rows
        .map(
          (row) => (
            fileId: row['id'] as String,
            description: row['description'] as String,
          ),
        )
        .toList();
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
  /// [excludeCollections] holds collections whose storage is currently
  /// unreachable — see `UnreachableCollections`. They are excluded *in the
  /// query* rather than skipped after it, which is the difference between a
  /// disconnected NAS costing nothing and it filling every batch of [limit]
  /// with files that cannot be read, starving the ones that can.
  Future<List<File>> getFilesWithMissingEmbeddings({
    int limit = 10,
    Set<String> excludeCollections = const {},
  }) async {
    final exclusion =
        excludeCollections.isEmpty
            ? ''
            : 'AND f.collection_id NOT IN '
                '(${List.filled(excludeCollections.length, '?').join(',')})';
    final rows = await db.select(
      '''
      SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner
      FROM files f
      LEFT OUTER JOIN files_embeddings fe
        ON fe.file_id = f.id AND fe.type = 'file'
      INNER JOIN collections c ON c.id = f.collection_id
      WHERE (fe.file_id IS NULL
             OR fe.qwen3_vl_embedding IS NULL
             OR IFNULL(fe.model_version, '') <> ?)
        AND (f.content_type = 'application/image' OR f.content_type LIKE 'image/%')
        AND f.is_deleted = 0
        AND f.is_inline = 0
        AND f.embedding_attempts < ?
        $exclusion
      LIMIT ?
      ''',
      [
        EmbeddingModel.current,
        maxEmbeddingAttempts,
        ...excludeCollections,
        limit,
      ],
    );
    return _filesWithResolvedPaths(rows);
  }

  /// Extensions the document queue offers to the extractor.
  ///
  /// A *hint*, not a decision: the server sniffs the bytes, because this
  /// archive holds RTF files named `.doc` (search plan §18a). All this list
  /// does is keep the queue from handing over photos and video.
  ///
  /// The queue cannot sniff — it has no bytes yet — so Workspace files are
  /// matched by content type instead of by name, and excluded from the
  /// extension branch entirely. A Google Doc named `Plan.md` matches `%.md`
  /// and is not markdown; extension is not format here either, and
  /// `content_type` is the only signal available before a read.

  /// Google Workspace types worth exporting, keyed on by content type because
  /// their names carry no reliable extension.
  ///
  /// Mirrors `FileBytesLoader.exportTargetFor`, which decides what each is
  /// fetched as. Kept as a literal list rather than derived from that map so
  /// the SQL stays a compile-time shape; the test asserts the two agree.
  static const exportableWorkspaceTypes = [
    'application/vnd.google-apps.document',
    'application/vnd.google-apps.spreadsheet',
    'application/vnd.google-apps.presentation',
  ];
  ///
  /// `htm`/`html` are excluded by policy — most are the HTML part of a mail
  /// whose body is already indexed, so indexing them creates a document that
  /// competes with its own email on identical text (§18i).
  ///
  /// **`ppt` is excluded but `pptx` is not**, and the difference is the
  /// parser rather than the medium. §18a-1 measured the *legacy binary*
  /// format at 43% parse yielding slide titles only; that is docling's CFB
  /// MS-PPT reader, not its OOXML one, so the finding does not carry over.
  /// `pptx` earns its place here because Google Slides now exports to it
  /// (§18k) — and a local `.pptx` and an exported deck should not be treated
  /// differently for no reason.
  ///
  /// **Spreadsheets are excluded entirely — `csv`, `xls`, `xlsx`.** A row is
  /// not a passage. Chunking one produces windows of delimited fields, and the
  /// embedding of a window of fields is not close to the embedding of any
  /// question a person asks, because there is no sentence in it for the model
  /// to place. They are also the most expensive format to chunk by a wide
  /// margin — 14 chunks a file against 4.7 for everything else — so they buy
  /// the least retrieval for the most vectors.
  ///
  /// Little is lost by it. A spreadsheet stays findable by name and metadata
  /// through `files_fts`, and a lookup in a table is a keyword lookup anyway.
  /// §18l then gives these files the semantic route their rows never could
  /// provide: a generated description, which is prose, and therefore lands in
  /// the same space as the question.
  ///
  /// This is also what retired the size gate's worst case: the three files
  /// that broke `HybridChunker` (§18a-2) were a stock export, a contact dump
  /// and a mailing list.
  static const documentExtensions = [
    'pdf', 'doc', 'docx', 'pptx', 'rtf', 'txt', 'md',
  ];

  /// Documents whose chunk set is missing or was built by an older model.
  ///
  /// **`NOT EXISTS`, never an outer join.** The join used by
  /// [getFilesWithMissingEmbeddings] is correct there only because `type='file'`
  /// is one row per file. A document has *many* chunk rows, so the same join
  /// emits one copy of the file per chunk it already owns — a batch of 100
  /// becomes a handful of files repeated dozens of times each, and the queue
  /// stops draining while appearing to work (§16d).
  ///
  /// Selecting on `model_version` is what makes a model upgrade re-chunk
  /// everything without a separate migration, and it is also why
  /// [replaceFileChunks] must be transactional: a half-written set carrying
  /// the current version reads here as finished.
  ///
  /// The version is read from `file_chunks`, not from the vectors, and the
  /// difference is load-bearing. A document too large to chunk (§18a-2) is
  /// stored as text with no vectors at all; asking the vector table whether it
  /// has been processed would answer "no" every pass and re-extract it
  /// forever. The chunk set is the record that this pipeline generation is
  /// finished with the file, whether or not it produced vectors.
  Future<List<File>> getFilesWithMissingChunks({
    int limit = 5,
    Set<String> excludeCollections = const {},
  }) async {
    final exclusion =
        excludeCollections.isEmpty
            ? ''
            : 'AND f.collection_id NOT IN '
                '(${List.filled(excludeCollections.length, '?').join(',')})';
    final extensionFilter = documentExtensions
        .map((_) => "lower(f.name) LIKE ?")
        .join(' OR ');
    final exportableTypes = List.filled(
      exportableWorkspaceTypes.length,
      '?',
    ).join(', ');
    final rows = await db.select(
      '''
      SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner
      FROM files f
      INNER JOIN collections c ON c.id = f.collection_id
      WHERE f.is_deleted = 0
        AND f.is_inline = 0
        AND (
              ($extensionFilter
               AND f.content_type NOT LIKE 'application/vnd.google-apps.%')
              OR f.content_type IN ($exportableTypes)
            )
        AND f.embedding_attempts < ?
        AND NOT EXISTS (
              SELECT 1 FROM file_chunks fc
              WHERE fc.file_id = f.id
                AND IFNULL(fc.model_version, '') = ?
            )
        $exclusion
      LIMIT ?
      ''',
      [
        ...documentExtensions.map((ext) => '%.$ext'),
        ...exportableWorkspaceTypes,
        maxEmbeddingAttempts,
        EmbeddingModel.current,
        ...excludeCollections,
        limit,
      ],
    );
    return _filesWithResolvedPaths(rows);
  }

  /// Images that have failed embedding this many times are dropped from
  /// [getFilesWithMissingEmbeddings].
  ///
  /// Without a cap a file that can *never* succeed is re-selected every batch,
  /// forever: the queue never drains, the aiserver is asked to decode the same
  /// broken bytes on a loop, and the log fills with identical errors. Measured
  /// on the dev archive this was 7 files — a truncated JPEG attached to a 1997
  /// email among them — cycling indefinitely.
  ///
  /// Mirrors [maxDescriptionAttempts], but what counts as an attempt is
  /// narrower and that difference is the whole design. See
  /// [incrementEmbeddingAttempts].
  static const maxEmbeddingAttempts = 5;

  /// Records that [fileId]'s bytes were read and the model rejected them.
  ///
  /// **Only for that case.** A file that could not be read at all — a photo on
  /// an unmounted NAS, a cloud file whose token needs refreshing, a laptop on
  /// a plane away from its home network — has demonstrated nothing about
  /// whether it can be embedded, and counting it would spend the budget on an
  /// outage. Five passes while a volume happens to be offline would retire the
  /// file permanently, and it would stay retired after the volume came back,
  /// with nothing in the UI to say a photo had been quietly dropped from
  /// semantic search. The caller distinguishes the two by whether the byte
  /// load returned null.
  Future<void> incrementEmbeddingAttempts(String fileId) async {
    await db.execute(
      'UPDATE files SET embedding_attempts = embedding_attempts + 1 '
      'WHERE id = ?',
      [fileId],
    );
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
    final extensionFilter = describableExtensions
        .map((_) => 'lower(f.name) LIKE ?')
        .join(' OR ');
    final exportableTypes = List.filled(
      exportableWorkspaceTypes.length,
      '?',
    ).join(', ');
    final rows = await db.select(
      '''
      SELECT f.*, c.path as col_path, c.local_copy_path, c.scanner
      FROM files f
      INNER JOIN collections c ON c.id = f.collection_id
      WHERE f.description IS NULL
        AND (
              f.content_type = 'application/image'
              OR f.content_type LIKE 'image/%'
              OR ($extensionFilter
                  AND f.content_type NOT LIKE 'application/vnd.google-apps.%')
              OR f.content_type IN ($exportableTypes)
            )
        AND f.is_deleted = 0
        AND f.is_inline = 0
        AND f.description_attempts < ?
      LIMIT ?
      ''',
      [
        ...describableExtensions.map((ext) => '%.$ext'),
        ...exportableWorkspaceTypes,
        maxDescriptionAttempts,
        limit,
      ],
    );
    return _filesWithResolvedPaths(rows);
  }

  /// Formats that can be *described*, which is a wider set than
  /// [documentExtensions] can be.
  ///
  /// Spreadsheets are the difference, and they are the reason §18l exists.
  /// They are excluded from chunking because a row is not a passage; a
  /// description is the one representation of a spreadsheet that *is* prose,
  /// so it lands in the same space as the question and gives back the semantic
  /// route the chunk exclusion took away. A file with no chunks and no
  /// description is reachable only by its filename.
  static const describableExtensions = [
    ...documentExtensions,
    'csv', 'xls', 'xlsx',
  ];

  /// The head of a document's already-extracted text, for describing it.
  ///
  /// Reads `file_chunks` rather than re-extracting: for anything the chunking
  /// path handled, the text is already on disk, and a second conversion of the
  /// same bytes would cost seconds per file to produce what is already there.
  /// Returns empty for a file with no chunks — a spreadsheet, or one not yet
  /// reached — and the caller falls back to reading it from the source.
  ///
  /// Ordered by `chunk_index`, so what comes back is the *opening* of the
  /// document. That is deliberate: a description is written from the title,
  /// the headings and the first passages, which is also where a document says
  /// what it is.
  Future<String> getDescriptionSourceText(
    String fileId, {
    int maxChars = 8000,
  }) async {
    final rows = await db.select(
      'SELECT text FROM file_chunks WHERE file_id = ? ORDER BY chunk_index',
      [fileId],
    );
    final buffer = StringBuffer();
    for (final row in rows) {
      if (buffer.length >= maxChars) break;
      buffer.writeln((row['text'] as String?) ?? '');
    }
    final text = buffer.toString();
    return text.length > maxChars ? text.substring(0, maxChars) : text;
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
            INSERT INTO files_embeddings
              (file_id, type, qwen3_vl_embedding, model_version)
            VALUES (?, 'description', vector_as_f32(?), ?)
            ON CONFLICT(file_id, type, sequence) DO UPDATE SET
              qwen3_vl_embedding = excluded.qwen3_vl_embedding,
              model_version = excluded.model_version
            ''',
            [fileId, jsonArray, EmbeddingModel.current],
          );
        } catch (e) {
          logger.w('vector_as_f32 unavailable, storing raw BLOB: $e');
          final blob = Float32List.fromList(embedding).buffer.asUint8List();
          await tx.execute(
            '''
            INSERT INTO files_embeddings
              (file_id, type, qwen3_vl_embedding, model_version)
            VALUES (?, 'description', ?, ?)
            ON CONFLICT(file_id, type, sequence) DO UPDATE SET
              qwen3_vl_embedding = excluded.qwen3_vl_embedding,
              model_version = excluded.model_version
            ''',
            [fileId, blob, EmbeddingModel.current],
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

  /// Replaces every stored chunk vector for [emailId] with [embeddings],
  /// storing values as packed Float32 BLOBs via `vector_as_f32()`.
  ///
  /// Chunk index is the position in [embeddings], so the caller's chunk order
  /// is the stored order.
  ///
  /// Replace rather than upsert, and in one transaction, because the number of
  /// chunks is a function of the body and the body can shrink — an email
  /// re-embedded after an edit, or after a scanner replaces a truncated
  /// snippet with the full text, can go from ten chunks to three. Upserting
  /// would update the first three and leave chunks 3–9 in place holding
  /// superseded text, still scored by every search, and never cleaned up by
  /// anything: they are not orphans, their `emails` row exists.
  ///
  /// Guarded on the `emails` row still existing, for the same reason as
  /// [upsertFileEmbedding].
  Future<void> replaceEmailEmbeddings(
    String emailId,
    List<List<double>> embeddings,
  ) async {
    if (embeddings.isEmpty) return;

    int affectedRows = 0;
    await db.transaction((tx) async {
      final exists = await tx.select(
        'SELECT 1 FROM emails WHERE id = ? LIMIT 1',
        [emailId],
      );
      if (exists.isEmpty) return;

      await tx.execute('DELETE FROM emails_embeddings WHERE email_id = ?', [
        emailId,
      ]);

      for (var index = 0; index < embeddings.length; index++) {
        final embedding = embeddings[index];
        try {
          final result = await tx.execute(
            '''
            INSERT INTO emails_embeddings
              (email_id, chunk_index, qwen3_vl_embedding, model_version)
            VALUES (?, ?, vector_as_f32(?), ?)
            ''',
            [
              emailId,
              index,
              '[${embedding.join(',')}]',
              EmbeddingModel.current,
            ],
          );
          affectedRows += result.affectedRows;
        } catch (e) {
          logger.w('vector_as_f32 unavailable, storing raw BLOB: $e');
          final blob = Float32List.fromList(embedding).buffer.asUint8List();
          final result = await tx.execute(
            '''
            INSERT INTO emails_embeddings
              (email_id, chunk_index, qwen3_vl_embedding, model_version)
            VALUES (?, ?, ?, ?)
            ''',
            [emailId, index, blob, EmbeddingModel.current],
          );
          affectedRows += result.affectedRows;
        }
      }
    });

    // See upsertFileEmbedding: a missing `emails` row is a silent no-op rather
    // than a failure — surface it loudly.
    if (affectedRows == 0) {
      logger.w(
        'replaceEmailEmbeddings: no rows written for emailId=$emailId — '
        'emails row missing or not yet visible to this connection',
      );
    } else {
      logger.d(
        'replaceEmailEmbeddings: emailId=$emailId chunks=$affectedRows '
        'dim=${embeddings.first.length}',
      );
    }
  }

  /// Replaces every stored chunk for [fileId] — text, provenance and vectors —
  /// in a single transaction.
  ///
  /// Unlike [replaceEmailEmbeddings] this spans two tables, because a document
  /// chunk is a vector *and* the footnote metadata that cites it: `file_chunks`
  /// holds the text, page and offsets, `files_embeddings` holds the vector at
  /// `type='chunk'`, and `(file_id, chunk_index)` in the first is
  /// `(file_id, sequence)` in the second. Splitting the write would let the two
  /// disagree about what a document contains.
  ///
  /// [embeddings] may be shorter than [chunks] — that is the §18a-2 gated case,
  /// where text was extracted but chunking was declined, so the document stays
  /// findable through `file_chunks_fts` with no vectors at all. It may not be
  /// *longer*: a vector with no chunk row is a hit that cannot be rendered.
  ///
  /// Replace rather than upsert, for the reason [replaceEmailEmbeddings] gives
  /// — a re-extracted document can be shorter, and the orphaned tail keeps its
  /// `files` row alive so no cascade ever reaps it. One transaction also keeps
  /// `model_version` honest: a crash midway through a non-transactional write
  /// leaves some chunks carrying the current version, which is exactly what
  /// [getFilesWithMissingChunks] reads as *finished*, freezing a half-indexed
  /// document forever.
  Future<void> replaceFileChunks(
    String fileId,
    List<FileChunk> chunks, {
    List<List<double>> embeddings = const [],
  }) async {
    if (embeddings.length > chunks.length) {
      throw ArgumentError(
        'replaceFileChunks: ${embeddings.length} embeddings for '
        '${chunks.length} chunks — a vector with no chunk row cannot be '
        'rendered as a result',
      );
    }

    int chunkRows = 0;
    await db.transaction((tx) async {
      final exists = await tx.select(
        'SELECT 1 FROM files WHERE id = ? LIMIT 1',
        [fileId],
      );
      if (exists.isEmpty) return;

      // Both deletes, always — a re-extraction that now yields no vectors
      // (gated) must not leave the previous run's vectors behind.
      await tx.execute('DELETE FROM file_chunks WHERE file_id = ?', [fileId]);
      await tx.execute(
        "DELETE FROM files_embeddings WHERE file_id = ? AND type = 'chunk'",
        [fileId],
      );

      for (final chunk in chunks) {
        final result = await tx.execute(
          '''
          INSERT INTO file_chunks
            (file_id, chunk_index, page, heading_path, char_start, char_end,
             text, model_version)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            fileId,
            chunk.chunkIndex,
            chunk.page,
            chunk.headingPath,
            chunk.charStart,
            chunk.charEnd,
            chunk.text,
            EmbeddingModel.current,
          ],
        );
        chunkRows += result.affectedRows;
      }

      for (var index = 0; index < embeddings.length; index++) {
        final embedding = embeddings[index];
        final sequence = chunks[index].chunkIndex;
        try {
          await tx.execute(
            '''
            INSERT INTO files_embeddings
              (file_id, type, sequence, qwen3_vl_embedding, model_version)
            VALUES (?, 'chunk', ?, vector_as_f32(?), ?)
            ''',
            [
              fileId,
              sequence,
              '[${embedding.join(',')}]',
              EmbeddingModel.current,
            ],
          );
        } catch (e) {
          logger.w('vector_as_f32 unavailable, storing raw BLOB: $e');
          final blob = Float32List.fromList(embedding).buffer.asUint8List();
          await tx.execute(
            '''
            INSERT INTO files_embeddings
              (file_id, type, sequence, qwen3_vl_embedding, model_version)
            VALUES (?, 'chunk', ?, ?, ?)
            ''',
            [fileId, sequence, blob, EmbeddingModel.current],
          );
        }
      }
    });

    // See upsertFileEmbedding: a missing `files` row makes this a silent
    // no-op rather than a failure, so it has to be said out loud.
    if (chunkRows == 0 && chunks.isNotEmpty) {
      logger.w(
        'replaceFileChunks: no rows written for fileId=$fileId — files row '
        'missing or not yet visible to this connection',
      );
    } else {
      logger.d(
        'replaceFileChunks: fileId=$fileId chunks=$chunkRows '
        'vectors=${embeddings.length}',
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

  /// Fetches the Qwen3-VL chunk embeddings for [emailId], in chunk order.
  /// Returns an empty list if the email has no embedding.
  Future<List<List<double>>> getEmailEmbeddings(String emailId) async {
    final rows = await db.select(
      'SELECT qwen3_vl_embedding FROM emails_embeddings '
      'WHERE email_id = ? ORDER BY chunk_index',
      [emailId],
    );
    return [
      for (final row in rows)
        if (row['qwen3_vl_embedding'] case final Uint8List blob)
          Float32List.view(
            blob.buffer,
            blob.offsetInBytes,
            blob.lengthInBytes ~/ Float32List.bytesPerElement,
          ).toList(),
    ];
  }

  /// Returns a list of emails carrying no current-pipeline embedding, limited
  /// to [limit] results.
  ///
  /// Phrased as `NOT EXISTS` rather than the outer join it replaced, because
  /// an email now owns one row per chunk: the join emitted a copy of a long
  /// email for every chunk it had, so a batch of 100 could hold four distinct
  /// emails and re-embed each of them dozens of times.
  ///
  /// "Has one valid row" is read as "is fully embedded", which holds because
  /// [replaceEmailEmbeddings] writes an email's chunks in a single transaction
  /// and the isolate declines to send a partial set. A half-written email
  /// would otherwise look finished here and never be completed.
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
      WHERE NOT EXISTS (
              SELECT 1 FROM emails_embeddings ee
              WHERE ee.email_id = e.id
                AND ee.qwen3_vl_embedding IS NOT NULL
                AND IFNULL(ee.model_version, '') = ?
            )
        AND e.is_deleted = 0
      LIMIT ?
      ''',
      [EmbeddingModel.current, limit],
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
