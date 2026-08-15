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
import 'package:mydatastudio/modules/photos/services/clustering/clustering_isolate.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// End-to-end test for the clustering isolate: spawn, read on the worker's own
/// connection, relay the finished tree back over the port, persist it on the
/// main isolate.
///
/// The pieces either side of this seam are unit tested — the arithmetic in
/// `spherical_kmeans_test`, the SQL and persistence in
/// `photo_cluster_repository_test`. What only this test covers is that they
/// actually meet: that a `Float32List` centroid survives the port, that the
/// worker can open a second connection to the same database file, and that
/// what lands in SQLite is the grouping the algorithm produced.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClusteringIsolate round trip', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = await io.Directory.systemTemp.createTemp('mds_cluster_iso_');

      const channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    /// Seeds [groups] x [perGroup] photos whose embeddings point along a
    /// distinct axis per group, so the correct grouping is unambiguous and the
    /// test asserts on the clustering rather than on a coin flip.
    Future<(String collectionId, List<List<String>> idsByGroup)> seed({
      required int groups,
      required int perGroup,
      String name = 'Photos',
    }) async {
      final collectionId = const Uuid().v4();
      await CollectionRepository(db).addCollection(
        Collection(
          id: collectionId,
          name: name,
          path: '/photos',
          type: 'file',
          scanner: 'local',
          needsReAuth: false,
          scanStatus: 'idle',
        ),
      );

      final fileRepo = FileDesktopRepository(db);
      final rng = Random(3);
      final idsByGroup = <List<String>>[];

      for (var g = 0; g < groups; g++) {
        final ids = <String>[];
        for (var i = 0; i < perGroup; i++) {
          final id = 'g$g-p$i-${const Uuid().v4()}';
          await fileRepo.create(
            File(
              id: id,
              name: 'IMG_${g}_$i.jpg',
              path: '/photos/IMG_${g}_$i.jpg',
              parent: '/photos',
              dateCreated: DateTime.now(),
              dateLastModified: DateTime.now(),
              collectionId: collectionId,
              contentType: 'image/jpeg',
              size: 1024,
              isDeleted: false,
            ),
          );

          final vector = Float32List(kClusterEmbeddingDim);
          for (var d = 0; d < kClusterEmbeddingDim; d++) {
            vector[d] = (rng.nextDouble() - 0.5) * 0.02;
          }
          vector[g] = 1.0;
          await db.execute(
            'INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding) '
            'VALUES (?, ?, ?)',
            [id, 'file', vector.buffer.asUint8List()],
          );
          ids.add(id);
        }
        idsByGroup.add(ids);
      }
      return (collectionId, idsByGroup);
    }

    test('spawns, clusters, and persists a run the main isolate can read',
        () async {
      final seeded = await seed(groups: 4, perGroup: 6);
      final idsByGroup = seeded.$2;

      final phases = <ClusteringPhase>[];
      final run = await ClusteringIsolate().run(
        scope: const ClusterScope.all(),
        storagePath: tempDir.path,
        dbName: db.name!,
        token: RootIsolateToken.instance!,
        maxGroups: 8,
        onProgress: (p) => phases.add(p.phase),
      );

      expect(run.photoCount, 24);
      expect(run.status, ClusterRunStatus.ready);
      expect(run.scope.isAll, isTrue);

      // The UI needs progress to move through the phases, not jump to done.
      expect(phases, contains(ClusteringPhase.loading));
      expect(phases, contains(ClusteringPhase.clustering));
      expect(phases, contains(ClusteringPhase.saving));

      final repo = PhotoClusterRepository(db);

      // Readable through the same path the UI uses.
      final found = await repo.latestReadyRun(const ClusterScope.all());
      expect(found, isNotNull);
      expect(found!.id, run.id);

      final tree = await repo.loadTree(run.id);
      expect(tree, isNotNull);
      expect(tree!.maxGroups, greaterThanOrEqualTo(4));

      // Centroids survived the port as real vectors, not zeros or garbage.
      for (final group in tree.allGroups) {
        expect(group.centroid.length, kClusterEmbeddingDim);
        var magnitude = 0.0;
        for (final v in group.centroid) {
          magnitude += v * v;
        }
        expect(sqrt(magnitude), closeTo(1.0, 1e-3),
            reason: 'centroid for node ${group.nodeId} is not a unit vector');
      }

      // The grouping is the one the data implies: at k=4 each seeded blob is
      // exactly one group.
      final membership = await repo.loadMembership(run.id);
      expect(membership.length, 24);

      for (final ids in idsByGroup) {
        final groupIds = ids
            .map((id) => tree.groupIdForLeaf(membership[id]!, 4))
            .toSet();
        expect(groupIds, hasLength(1),
            reason: 'a seeded blob was split across groups at k=4');
      }
      final distinct = {
        for (final ids in idsByGroup)
          tree.groupIdForLeaf(membership[ids.first]!, 4),
      };
      expect(distinct, hasLength(4), reason: 'blobs were merged at k=4');
    });

    test('scopes a run to the selected collection', () async {
      final a = await seed(groups: 2, perGroup: 4, name: 'Local');
      final b = await seed(groups: 3, perGroup: 3, name: 'Gmail');

      final run = await ClusteringIsolate().run(
        scope: ClusterScope([b.$1]),
        storagePath: tempDir.path,
        dbName: db.name!,
        token: RootIsolateToken.instance!,
        maxGroups: 6,
      );

      expect(run.photoCount, 9);
      expect(run.scope.collectionIds, [b.$1]);

      final membership =
          await PhotoClusterRepository(db).loadMembership(run.id);
      expect(membership.keys.toSet(), b.$2.expand((e) => e).toSet());
      for (final id in a.$2.expand((e) => e)) {
        expect(membership.containsKey(id), isFalse);
      }
    });

    // A photo the user hid must not shape the groups. This is the cross-track
    // guarantee: cleanup and clustering have to agree about what is in the
    // gallery, or hiding a photo would still leave it naming a group.
    test('excludes hidden photos from the run', () async {
      final seeded = await seed(groups: 3, perGroup: 4);
      final hidden = seeded.$2.first.first;
      await db.execute('UPDATE files SET is_hidden = 1 WHERE id = ?', [hidden]);

      final run = await ClusteringIsolate().run(
        scope: const ClusterScope.all(),
        storagePath: tempDir.path,
        dbName: db.name!,
        token: RootIsolateToken.instance!,
        maxGroups: 6,
      );

      expect(run.photoCount, 11);
      final membership =
          await PhotoClusterRepository(db).loadMembership(run.id);
      expect(membership.containsKey(hidden), isFalse);
    });

    test('fails with a usable message when nothing is embedded', () async {
      await seed(groups: 1, perGroup: 2);
      await db.execute('DELETE FROM files_embeddings');

      expect(
        () => ClusteringIsolate().run(
          scope: const ClusterScope.all(),
          storagePath: tempDir.path,
          dbName: db.name!,
          token: RootIsolateToken.instance!,
        ),
        throwsA(isA<ClusteringFailure>().having(
          (e) => e.message,
          'message',
          contains('embedded'),
        )),
      );
    });
  });
}
