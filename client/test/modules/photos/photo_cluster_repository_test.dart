import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_repository.dart';
import 'package:mydatastudio/modules/photos/services/clustering/spherical_kmeans.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

const int _dim = 32;

Float32List _centroid(int seed) {
  final out = Float32List(_dim);
  out[seed % _dim] = 1.0;
  return out;
}

/// Groups of unit vectors, each clustered tightly around its own axis, so the
/// correct partition is unambiguous.
Float32List _blobs({
  required int groups,
  required int perGroup,
  double jitter = 0.05,
}) {
  final rng = Random(11);
  final data = Float32List(groups * perGroup * _dim);
  var row = 0;
  for (var g = 0; g < groups; g++) {
    for (var i = 0; i < perGroup; i++) {
      final offset = row * _dim;
      for (var d = 0; d < _dim; d++) {
        data[offset + d] = (rng.nextDouble() - 0.5) * jitter;
      }
      data[offset + g] = 1.0;
      row++;
    }
  }
  l2NormalizeRows(data, _dim);
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Photo clustering persistence', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late PhotoClusterRepository repo;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = await io.Directory.systemTemp.createTemp('mds_cluster_test_');

      const channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;
      repo = PhotoClusterRepository(db);
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    /// Creates a collection with [count] image files and returns their ids.
    /// Cluster membership rows carry a foreign key to `files`, so the rows have
    /// to exist before a run can be saved.
    Future<(String collectionId, List<String> fileIds)> seedPhotos(
      int count, {
      String? name,
    }) async {
      final collectionId = const Uuid().v4();
      await CollectionRepository(db).addCollection(
        Collection(
          id: collectionId,
          name: name ?? 'Photos',
          path: '/photos',
          type: 'file',
          scanner: 'local',
          needsReAuth: false,
          scanStatus: 'idle',
        ),
      );

      final fileRepo = FileDesktopRepository(db);
      final ids = <String>[];
      for (var i = 0; i < count; i++) {
        final id = 'file-$i-${const Uuid().v4()}';
        await fileRepo.create(
          File(
            id: id,
            name: 'IMG_$i.jpg',
            path: '/photos/IMG_$i.jpg',
            parent: '/photos',
            dateCreated: DateTime.now(),
            dateLastModified: DateTime.now(),
            collectionId: collectionId,
            contentType: 'image/jpeg',
            size: 1024,
            isDeleted: false,
          ),
        );
        ids.add(id);
      }
      return (collectionId, ids);
    }

    /// Persists a real clustering result over [groups] x [perGroup] synthetic
    /// photos and hands back both sides so they can be compared.
    Future<(ClusterTree computed, PhotoClusterTree stored, List<String> fileIds)>
        clusterAndSave({
      int groups = 5,
      int perGroup = 8,
      int maxGroups = 12,
      ClusterScope scope = const ClusterScope.all(),
      String? collectionId,
    }) async {
      final data = _blobs(groups: groups, perGroup: perGroup);
      final computed = buildClusterTree(data, _dim, maxGroups: maxGroups);

      final seeded = await seedPhotos(groups * perGroup);
      final fileIds = seeded.$2;

      final splitRank = <int, int>{};
      for (var i = 0; i < computed.splitOrder.length; i++) {
        splitRank[computed.splitOrder[i]] = i;
      }

      final membership = <String, int>{};
      for (final node in computed.leavesAt(computed.maxGroups)) {
        for (final index in node.members) {
          membership[fileIds[index]] = node.id;
        }
      }

      final run = ClusterRun(
        id: const Uuid().v4(),
        scope: collectionId != null ? ClusterScope([collectionId]) : scope,
        createdAt: DateTime.now(),
        photoCount: fileIds.length,
        maxGroups: maxGroups,
        seed: 0x5EED,
        status: ClusterRunStatus.ready,
      );

      await repo.saveRun(
        run,
        [
          for (final node in computed.nodes)
            ClusterGroup(
              runId: run.id,
              nodeId: node.id,
              parentId: node.parentId,
              splitRank: splitRank[node.id],
              memberCount: node.size,
              coherence: node.coherence,
              centroid: node.centroid,
            ),
        ],
        membership,
      );

      final stored = await repo.loadTree(run.id);
      return (computed, stored!, fileIds);
    }

    test('cluster tables exist after schema init', () async {
      final rows = await db.select(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final names = rows.map((r) => r['name'] as String).toSet();
      expect(names, containsAll(<String>{
        'photo_cluster_runs',
        'photo_cluster_nodes',
        'photo_cluster_members',
      }));
    });

    test('files.is_hidden column is added on open', () async {
      final columns = (await db.select("PRAGMA table_info(files)"))
          .map((r) => r['name'] as String)
          .toSet();
      expect(columns, contains('is_hidden'));
    });

    /// Writes a raw Float32 BLOB straight into `files_embeddings`. Bypasses
    /// `vector_as_f32()` deliberately: these tests only need the bytes back,
    /// and the sqlite_vector extension isn't loaded in unit tests.
    Future<void> seedEmbedding(
      String fileId, {
      String type = 'file',
      int dim = kClusterEmbeddingDim,
    }) async {
      final vector = Float32List(dim);
      vector[0] = 1.0;
      await db.execute(
        'INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding) '
        'VALUES (?, ?, ?)',
        [fileId, type, vector.buffer.asUint8List()],
      );
    }

    group('loadEmbeddingsForScope', () {
      test('returns one row per embedded image, packed contiguously', () async {
        final seeded = await seedPhotos(3);
        for (final id in seeded.$2) {
          await seedEmbedding(id);
        }

        final loaded =
            await repo.loadEmbeddingsForScope(const ClusterScope.all());
        expect(loaded.fileIds, hasLength(3));
        expect(loaded.vectors.length, 3 * kClusterEmbeddingDim);
        // Row-major: each row's first component is the 1.0 that was written.
        for (var i = 0; i < 3; i++) {
          expect(loaded.vectors[i * kClusterEmbeddingDim], closeTo(1.0, 1e-6));
        }
      });

      // Where the cleanup track meets clustering. A photo the user removed from
      // the gallery must not pull a group toward itself, and must never end up
      // being the photo a group gets named after.
      test('excludes hidden photos', () async {
        final seeded = await seedPhotos(3);
        for (final id in seeded.$2) {
          await seedEmbedding(id);
        }
        await db.execute('UPDATE files SET is_hidden = 1 WHERE id = ?', [
          seeded.$2.first,
        ]);

        final loaded =
            await repo.loadEmbeddingsForScope(const ClusterScope.all());
        expect(loaded.fileIds, hasLength(2));
        expect(loaded.fileIds, isNot(contains(seeded.$2.first)));
        expect(loaded.vectors.length, 2 * kClusterEmbeddingDim);
      });

      test('excludes deleted, inline, and caption embeddings', () async {
        final seeded = await seedPhotos(4);
        final ids = seeded.$2;
        for (final id in ids) {
          await seedEmbedding(id);
        }
        await db.execute('UPDATE files SET is_deleted = 1 WHERE id = ?', [ids[0]]);
        await db.execute('UPDATE files SET is_inline = 1 WHERE id = ?', [ids[1]]);
        // A caption embedding for a photo that has no image embedding must not
        // stand in for one — they are different vector spaces.
        await db.execute('DELETE FROM files_embeddings WHERE file_id = ?', [ids[2]]);
        await seedEmbedding(ids[2], type: 'description');

        final loaded =
            await repo.loadEmbeddingsForScope(const ClusterScope.all());
        expect(loaded.fileIds, [ids[3]]);
      });

      test('honours a collection scope', () async {
        final a = await seedPhotos(2, name: 'Local');
        final b = await seedPhotos(3, name: 'Gmail');
        for (final id in [...a.$2, ...b.$2]) {
          await seedEmbedding(id);
        }

        final scoped = await repo.loadEmbeddingsForScope(ClusterScope([b.$1]));
        expect(scoped.fileIds.toSet(), b.$2.toSet());

        final all = await repo.loadEmbeddingsForScope(const ClusterScope.all());
        expect(all.fileIds, hasLength(5));
      });

      // A wrong-length vector would shift every following row in the packed
      // buffer, silently corrupting the clustering of every photo after it.
      test('skips malformed vectors without shifting the buffer', () async {
        final seeded = await seedPhotos(3);
        await seedEmbedding(seeded.$2[0]);
        await seedEmbedding(seeded.$2[1], dim: 64); // wrong dimension
        await seedEmbedding(seeded.$2[2]);

        final loaded =
            await repo.loadEmbeddingsForScope(const ClusterScope.all());
        expect(loaded.fileIds, hasLength(2));
        expect(loaded.fileIds, isNot(contains(seeded.$2[1])));
        expect(loaded.vectors.length, 2 * kClusterEmbeddingDim);
        for (var i = 0; i < 2; i++) {
          expect(loaded.vectors[i * kClusterEmbeddingDim], closeTo(1.0, 1e-6));
        }
      });
    });

    test('a saved run round-trips its tree shape and centroids', () async {
      final (computed, stored, _) = await clusterAndSave();

      expect(stored.allGroups.length, computed.nodes.length);
      expect(stored.maxGroups, computed.maxGroups);

      for (final node in computed.nodes) {
        final group = stored.group(node.id)!;
        expect(group.parentId, node.parentId);
        expect(group.memberCount, node.size);
        expect(group.coherence, closeTo(node.coherence, 1e-5));
        expect(group.centroid.length, _dim);
        for (var d = 0; d < _dim; d++) {
          expect(group.centroid[d], closeTo(node.centroid[d], 1e-6));
        }
      }
    });

    // The whole point of storing `split_rank`: the slider must be able to
    // reproduce the algorithm's grouping from the database alone, without
    // re-running k-means. If these two ever disagree, the view silently shows
    // a different grouping than the one that was computed and labeled.
    test('stored tree reproduces the computed grouping at every k', () async {
      final (computed, stored, fileIds) = await clusterAndSave();

      for (var k = 1; k <= computed.maxGroups; k++) {
        final computedGroups = computed.leavesAt(k);
        final storedGroups = stored.groupsAt(k);

        expect(storedGroups.map((g) => g.nodeId).toSet(),
            computedGroups.map((n) => n.id).toSet(),
            reason: 'group ids differ at k=$k');

        // And the same photos land in the same group, resolved through the
        // stored deepest-leaf membership rather than the in-memory members.
        final membership = await repo.loadMembership(stored.run.id);
        for (final node in computedGroups) {
          final expectedFiles = {for (final i in node.members) fileIds[i]};
          final actualFiles = {
            for (final entry in membership.entries)
              if (stored.groupIdForLeaf(entry.value, k) == node.id) entry.key,
          };
          expect(actualFiles, expectedFiles,
              reason: 'membership differs for group ${node.id} at k=$k');
        }
      }
    });

    test('every photo belongs to exactly one group at every k', () async {
      final (computed, stored, fileIds) = await clusterAndSave();
      final membership = await repo.loadMembership(stored.run.id);
      expect(membership.length, fileIds.length);

      for (var k = 1; k <= stored.maxGroups; k++) {
        final counts = <int, int>{};
        for (final leaf in membership.values) {
          final groupId = stored.groupIdForLeaf(leaf, k);
          expect(groupId, isNotNull, reason: 'unresolved leaf at k=$k');
          counts[groupId!] = (counts[groupId] ?? 0) + 1;
        }
        expect(counts.length, k, reason: 'wrong number of occupied groups at k=$k');
        expect(counts.values.reduce((a, b) => a + b), fileIds.length,
            reason: 'photos lost or double counted at k=$k');
      }
      expect(computed.maxGroups, stored.maxGroups);
    });

    test('fileIdsUnder resolves an interior node to its whole subtree',
        () async {
      final (computed, stored, fileIds) = await clusterAndSave();

      // The root owns everything, whichever leaves it was split into.
      final rootId = computed.nodes.first.id;
      final underRoot = await repo.fileIdsUnder(stored.run.id, rootId);
      expect(underRoot.toSet(), fileIds.toSet());

      // A node split once owns exactly its two children's photos.
      final split = computed.nodes.firstWhere((n) => n.isSplit && n.id != rootId);
      final underSplit = await repo.fileIdsUnder(stored.run.id, split.id);
      expect(underSplit, hasLength(split.size));
      expect(underSplit.toSet(), {for (final i in split.members) fileIds[i]});
    });

    test('latestReadyRun keeps scopes apart and ignores incomplete runs',
        () async {
      final seeded = await seedPhotos(4, name: 'Gmail');
      final collectionId = seeded.$1;

      expect(await repo.latestReadyRun(const ClusterScope.all()), isNull);

      final (_, allRun, _) = await clusterAndSave();
      final foundAll = await repo.latestReadyRun(const ClusterScope.all());
      expect(foundAll, isNotNull);
      expect(foundAll!.id, allRun.run.id);

      // A run scoped to one collection must not be handed back for All Photos.
      expect(
        await repo.latestReadyRun(ClusterScope([collectionId])),
        isNull,
      );

      // A run left in `building` — the state a crash mid-write leaves behind —
      // has an incomplete tree and must never reach the UI.
      await db.execute(
        'UPDATE photo_cluster_runs SET status = ? WHERE id = ?',
        [ClusterRunStatus.building.name, allRun.run.id],
      );
      expect(await repo.latestReadyRun(const ClusterScope.all()), isNull);
    });

    // The query used to say `status != building`, which let `stale` through.
    // Nothing calls markStale yet, so it passed on a technicality — and would
    // have started handing back retired runs the day something did. A method
    // called latestReadyRun has to mean it.
    test('latestReadyRun excludes a run that has been retired', () async {
      final (_, stored, _) = await clusterAndSave();
      expect((await repo.latestReadyRun(const ClusterScope.all()))?.id,
          stored.run.id);

      await repo.markStale(stored.run.id);

      expect(await repo.latestReadyRun(const ClusterScope.all()), isNull,
          reason: 'a stale run is retired, not the latest ready one');
    });

    test('deleting a run cascades to its nodes and members', () async {
      final (_, stored, _) = await clusterAndSave();
      await repo.deleteRun(stored.run.id);

      final nodes = await db.select(
        'SELECT count(*) c FROM photo_cluster_nodes WHERE run_id = ?',
        [stored.run.id],
      );
      final members = await db.select(
        'SELECT count(*) c FROM photo_cluster_members WHERE run_id = ?',
        [stored.run.id],
      );
      expect(nodes.first['c'], 0);
      expect(members.first['c'], 0);
    });

    // Labelling a run is minutes of vision calls, so reopening at a different
    // cut than the one those labels were watched onto throws the wait away.
    test('the group slider position is remembered per run', () async {
      final (_, stored, _) = await clusterAndSave();
      expect(stored.run.lastGroupCount, isNull,
          reason: 'nothing remembered until the user moves the slider');

      await repo.saveGroupCount(stored.run.id, 82);

      final reloaded = await repo.loadTree(stored.run.id);
      expect(reloaded!.run.lastGroupCount, 82);

      // And through the path the view actually loads by.
      final found = await repo.latestReadyRun(const ClusterScope.all());
      expect(found!.lastGroupCount, 82);
    });

    test('each scope remembers its own position', () async {
      final seeded = await seedPhotos(4, name: 'Gmail');
      final scoped = ClusterScope([seeded.$1]);

      final (_, allRun, _) = await clusterAndSave();
      await repo.saveGroupCount(allRun.run.id, 82);

      final run = ClusterRun(
        id: const Uuid().v4(),
        scope: scoped,
        createdAt: DateTime.now(),
        photoCount: 4,
        maxGroups: 4,
        seed: 1,
        status: ClusterRunStatus.ready,
      );
      await repo.saveRun(run, [
        ClusterGroup(
          runId: run.id,
          nodeId: 0,
          parentId: null,
          splitRank: null,
          memberCount: 4,
          coherence: 1.0,
          centroid: _centroid(1),
        ),
      ], const {});
      await repo.saveGroupCount(run.id, 6);

      expect((await repo.latestReadyRun(const ClusterScope.all()))!.lastGroupCount, 82);
      expect((await repo.latestReadyRun(scoped))!.lastGroupCount, 6);
    });

    test('labels persist per node and survive reload', () async {
      final (_, stored, _) = await clusterAndSave();
      final target = stored.groupsAt(3).first;

      expect(target.label, isNull);
      expect(target.displayLabel, 'Group ${target.nodeId}');

      await repo.updateLabel(
        stored.run.id,
        target.nodeId,
        'Lighthouses',
        ClusterLabelStatus.ready,
      );

      final reloaded = await repo.loadTree(stored.run.id);
      final group = reloaded!.group(target.nodeId)!;
      expect(group.label, 'Lighthouses');
      expect(group.labelStatus, ClusterLabelStatus.ready);
      expect(group.displayLabel, 'Lighthouses');
    });

    test('pruneOldRuns keeps only the most recent runs', () async {
      for (var i = 0; i < 6; i++) {
        final run = ClusterRun(
          id: 'run-$i',
          scope: ClusterScope(['col-$i']),
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000 + i),
          photoCount: 1,
          maxGroups: 2,
          seed: 1,
          status: ClusterRunStatus.ready,
        );
        await repo.saveRun(
          run,
          [
            ClusterGroup(
              runId: run.id,
              nodeId: 0,
              parentId: null,
              splitRank: null,
              memberCount: 1,
              coherence: 1.0,
              centroid: _centroid(i),
            ),
          ],
          const {},
        );
      }

      await repo.pruneOldRuns(keep: 2);
      final remaining = await db.select(
        'SELECT id FROM photo_cluster_runs ORDER BY created_at DESC',
      );
      expect(remaining.map((r) => r['id']), ['run-5', 'run-4']);
    });
  });

  group('ClusterScope', () {
    // The scope key is how a run is matched to the drawer's current filter.
    // If selection order changed the key, switching between two collections and
    // back would miss the cached run and silently re-cluster.
    test('key is independent of the order collections were selected', () {
      expect(
        const ClusterScope(['b', 'a', 'c']).key,
        const ClusterScope(['a', 'c', 'b']).key,
      );
      expect(const ClusterScope(['b', 'a']), const ClusterScope(['a', 'b']));
    });

    test('All Photos is a null key, distinct from any collection selection', () {
      expect(const ClusterScope.all().key, isNull);
      expect(const ClusterScope([]).key, isNull);
      expect(const ClusterScope(['a']).key, 'a');
      expect(ClusterScope.fromKey(null).isAll, isTrue);
      expect(ClusterScope.fromKey('a,b').collectionIds, ['a', 'b']);
    });
  });
}
