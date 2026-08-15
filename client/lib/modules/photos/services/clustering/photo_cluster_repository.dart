import 'dart:typed_data';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';

/// Dimension of the Qwen3-VL embeddings in `files_embeddings`.
const int kClusterEmbeddingDim = 2048;

/// Every in-scope photo's embedding, packed for clustering.
typedef ScopedEmbeddings = ({List<String> fileIds, Float32List vectors});

/// resqlite query layer for photo clustering.
///
/// Lives in the photos module rather than top-level `repositories/` because
/// nothing outside photos reads these tables — the same reason
/// `photos_repository.dart` sits here.
class PhotoClusterRepository {
  PhotoClusterRepository(this.db);

  final AppDatabase db;
  final AppLogger logger = AppLogger(null);

  /// Reads every in-scope image embedding into one contiguous buffer.
  ///
  /// Packed into a single [Float32List] rather than a list of vectors because
  /// the clustering inner loop is a dot product over rows; one allocation keeps
  /// those rows contiguous instead of chasing thousands of separate heap
  /// objects.
  ///
  /// Excludes hidden photos as well as deleted ones. Hiding is the user saying
  /// "this isn't part of my gallery", and a hidden photo that still pulled a
  /// group toward itself — or worse, got a group named after it — would make
  /// the cleanup workflow feel broken.
  ///
  /// Rows whose BLOB is not exactly `dim * 4` bytes are skipped. A short or
  /// oversized vector means a partially written or wrong-model embedding, and
  /// letting one through would shift every subsequent row in the buffer.
  Future<ScopedEmbeddings> loadEmbeddingsForScope(ClusterScope scope) async {
    final ids = scope.isAll ? const <String>[] : scope.collectionIds!;
    final scopeClause = ids.isEmpty
        ? ''
        : 'AND f.collection_id IN (${List.filled(ids.length, '?').join(',')})';

    final rows = await db.select(
      '''
      SELECT e.file_id, e.qwen3_vl_embedding
      FROM files_embeddings e
      JOIN files f ON f.id = e.file_id
      WHERE e.type = 'file'
        AND e.qwen3_vl_embedding IS NOT NULL
        AND f.is_deleted = 0
        AND f.is_user_deleted = 0
        AND f.is_hidden = 0
        AND f.is_inline = 0
        AND (f.content_type = 'application/image'
             OR f.content_type LIKE 'image/%')
        $scopeClause
      ORDER BY e.file_id
      ''',
      [...ids],
    );

    const expectedBytes = kClusterEmbeddingDim * 4;
    final fileIds = <String>[];
    final vectors = Float32List(rows.length * kClusterEmbeddingDim);
    var row = 0;

    for (final r in rows) {
      final blob = r['qwen3_vl_embedding'] as Uint8List;
      if (blob.lengthInBytes != expectedBytes) {
        logger.w(
          'PhotoClusterRepository: skipping ${r['file_id']} — '
          '${blob.lengthInBytes} bytes, expected $expectedBytes',
        );
        continue;
      }
      // Copy before viewing: the row's buffer carries no alignment guarantee,
      // and Float32List.sublistView throws on an unaligned offset.
      final floats = Float32List.sublistView(Uint8List.fromList(blob));
      vectors.setRange(
        row * kClusterEmbeddingDim,
        (row + 1) * kClusterEmbeddingDim,
        floats,
      );
      fileIds.add(r['file_id'] as String);
      row++;
    }

    // Skipped rows leave a tail of zeros; hand back only what was filled so a
    // malformed vector can't become a phantom photo at the origin.
    return (
      fileIds: fileIds,
      vectors: Float32List.sublistView(vectors, 0, row * kClusterEmbeddingDim),
    );
  }

  /// How many photos a run over [scope] would cover.
  ///
  /// Needed before clustering, because the tree's ceiling is derived from the
  /// library's size and the tree has to be built to that ceiling in one pass.
  /// Deliberately mirrors [loadEmbeddingsForScope]'s filters — a count that
  /// disagreed with what actually gets clustered would size the slider for a
  /// library that isn't there.
  Future<int> countPhotosInScope(ClusterScope scope) async {
    final ids = scope.isAll ? const <String>[] : scope.collectionIds!;
    final scopeClause = ids.isEmpty
        ? ''
        : 'AND f.collection_id IN (${List.filled(ids.length, '?').join(',')})';

    final rows = await db.select(
      '''
      SELECT count(*) AS c
      FROM files_embeddings e
      JOIN files f ON f.id = e.file_id
      WHERE e.type = 'file'
        AND e.qwen3_vl_embedding IS NOT NULL
        AND f.is_deleted = 0
        AND f.is_user_deleted = 0
        AND f.is_hidden = 0
        AND f.is_inline = 0
        AND (f.content_type = 'application/image'
             OR f.content_type LIKE 'image/%')
        $scopeClause
      ''',
      [...ids],
    );
    return rows.isEmpty ? 0 : (rows.first['c'] as int? ?? 0);
  }

  /// Persists a completed run: the run row, its tree, and one membership row
  /// per photo against its deepest leaf.
  ///
  /// One transaction for the whole run. A half-written tree is worse than no
  /// tree — [PhotoClusterTree] resolves a photo's group by walking `parentId`
  /// to the root, so a missing interior node silently drops photos out of
  /// every group rather than failing loudly.
  ///
  /// Writes `status = ready` last, so a crash mid-write leaves a run that
  /// [latestReadyRun] will not hand to the UI.
  Future<void> saveRun(
    ClusterRun run,
    List<ClusterGroup> groups,
    Map<String, int> leafByFileId,
  ) async {
    await db.transaction((tx) async {
      // Replacing a run for the same scope: cascade clears its nodes and
      // members, so this doesn't need to delete them by hand.
      await tx.execute('DELETE FROM photo_cluster_runs WHERE id = ?', [run.id]);

      final building = run.copyWith(status: ClusterRunStatus.building).toMap();
      await tx.execute(
        'INSERT INTO photo_cluster_runs '
        '(id, collection_scope, created_at, photo_count, max_groups, seed, status) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          building['id'],
          building['collection_scope'],
          building['created_at'],
          building['photo_count'],
          building['max_groups'],
          building['seed'],
          building['status'],
        ],
      );

      for (final group in groups) {
        final map = group.toMap();
        await tx.execute(
          'INSERT INTO photo_cluster_nodes '
          '(run_id, node_id, parent_id, split_rank, member_count, coherence, '
          ' centroid, representatives, label, label_status) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            map['run_id'],
            map['node_id'],
            map['parent_id'],
            map['split_rank'],
            map['member_count'],
            map['coherence'],
            map['centroid'],
            map['representatives'],
            map['label'],
            map['label_status'],
          ],
        );
      }

      for (final entry in leafByFileId.entries) {
        await tx.execute(
          'INSERT INTO photo_cluster_members (run_id, node_id, file_id) '
          'VALUES (?, ?, ?)',
          [run.id, entry.value, entry.key],
        );
      }

      await tx.execute(
        'UPDATE photo_cluster_runs SET status = ? WHERE id = ?',
        [ClusterRunStatus.ready.name, run.id],
      );
    });

    logger.i(
      'PhotoClusterRepository: saved run ${run.id} — '
      '${groups.length} nodes, ${leafByFileId.length} photos',
    );
  }

  /// The newest usable run for [scope], or null if none has completed.
  ///
  /// `status = building` rows are excluded: a run still being written, or one
  /// abandoned by a crash, has an incomplete tree.
  Future<ClusterRun?> latestReadyRun(ClusterScope scope) async {
    final key = scope.key;
    final rows = await db.select(
      'SELECT * FROM photo_cluster_runs '
      'WHERE status != ? AND collection_scope IS ? '
      'ORDER BY created_at DESC LIMIT 1',
      [ClusterRunStatus.building.name, key],
    );
    if (rows.isEmpty) return null;
    return ClusterRun.fromMap(rows.first);
  }

  /// Loads a run's whole tree. Cheap — a run has at most a few hundred nodes.
  Future<PhotoClusterTree?> loadTree(String runId) async {
    final runRows = await db.select(
      'SELECT * FROM photo_cluster_runs WHERE id = ?',
      [runId],
    );
    if (runRows.isEmpty) return null;

    final nodeRows = await db.select(
      'SELECT * FROM photo_cluster_nodes WHERE run_id = ?',
      [runId],
    );
    if (nodeRows.isEmpty) return null;

    return PhotoClusterTree(
      ClusterRun.fromMap(runRows.first),
      nodeRows.map(ClusterGroup.fromMap).toList(),
    );
  }

  /// Every photo in the run mapped to its deepest leaf.
  ///
  /// Loaded once per run and kept in memory: resolving groups for a new slider
  /// position is then a walk up the tree per photo, with no further queries.
  Future<Map<String, int>> loadMembership(String runId) async {
    final rows = await db.select(
      'SELECT file_id, node_id FROM photo_cluster_members WHERE run_id = ?',
      [runId],
    );
    return {
      for (final row in rows) row['file_id'] as String: row['node_id'] as int,
    };
  }

  /// The file ids under [nodeId], in no particular order.
  ///
  /// Interior nodes own their descendants' members, so this resolves the
  /// subtree in SQL rather than pulling the whole membership map — used by the
  /// labeling job, which works one group at a time.
  Future<List<String>> fileIdsUnder(String runId, int nodeId) async {
    final rows = await db.select(
      '''
      WITH RECURSIVE subtree(node_id) AS (
        SELECT ?
        UNION ALL
        SELECT n.node_id FROM photo_cluster_nodes n
        JOIN subtree s ON n.parent_id = s.node_id
        WHERE n.run_id = ?
      )
      SELECT m.file_id FROM photo_cluster_members m
      WHERE m.run_id = ? AND m.node_id IN (SELECT node_id FROM subtree)
      ''',
      [nodeId, runId, runId],
    );
    return [for (final row in rows) row['file_id'] as String];
  }

  /// `files.thumbnail` for [fileIds], keyed by file id.
  ///
  /// Only rows that still exist come back, so a photo deleted since the run was
  /// built is simply absent rather than an error — the caller is picking images
  /// to show a model and can do without any one of them.
  Future<Map<String, String>> thumbnailKeysFor(List<String> fileIds) async {
    if (fileIds.isEmpty) return const {};
    final placeholders = List.filled(fileIds.length, '?').join(',');
    final rows = await db.select(
      'SELECT id, thumbnail FROM files '
      'WHERE id IN ($placeholders) AND thumbnail IS NOT NULL',
      fileIds,
    );
    return {
      for (final row in rows)
        row['id'] as String: row['thumbnail'] as String,
    };
  }

  Future<void> updateLabel(
    String runId,
    int nodeId,
    String? label,
    ClusterLabelStatus status,
  ) async {
    await db.execute(
      'UPDATE photo_cluster_nodes SET label = ?, label_status = ? '
      'WHERE run_id = ? AND node_id = ?',
      [label, status.name, runId, nodeId],
    );
  }

  Future<void> markStale(String runId) async {
    await db.execute('UPDATE photo_cluster_runs SET status = ? WHERE id = ?', [
      ClusterRunStatus.stale.name,
      runId,
    ]);
  }

  Future<void> deleteRun(String runId) async {
    await db.execute('DELETE FROM photo_cluster_runs WHERE id = ?', [runId]);
  }

  /// Drops all but the [keep] most recent runs.
  ///
  /// Each source filter the user visits builds its own run, and every run
  /// stores a centroid per node plus a row per photo. Without a cap, browsing
  /// through collections would accumulate trees nobody will look at again.
  Future<void> pruneOldRuns({int keep = 4}) async {
    final rows = await db.select(
      'SELECT id FROM photo_cluster_runs ORDER BY created_at DESC LIMIT -1 OFFSET ?',
      [keep],
    );
    for (final row in rows) {
      await deleteRun(row['id'] as String);
    }
    if (rows.isNotEmpty) {
      logger.d('PhotoClusterRepository: pruned ${rows.length} old runs');
    }
  }
}
