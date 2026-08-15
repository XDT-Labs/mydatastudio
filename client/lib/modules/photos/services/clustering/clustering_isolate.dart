import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_repository.dart';
import 'package:mydatastudio/modules/photos/services/clustering/spherical_kmeans.dart';
import 'package:uuid/uuid.dart';

/// What the isolate is doing, for a determinate progress bar.
enum ClusteringPhase { loading, clustering, saving }

class ClusteringProgress {
  const ClusteringProgress(this.phase, {this.current = 0, this.total = 0});

  final ClusteringPhase phase;
  final int current;
  final int total;

  double? get fraction => total <= 0 ? null : (current / total).clamp(0.0, 1.0);
}

/// Thrown when a run cannot be produced. Distinguished from a crash so the UI
/// can say why — most often that nothing in scope has been embedded yet.
class ClusteringFailure implements Exception {
  ClusteringFailure(this.message);
  final String message;
  @override
  String toString() => 'ClusteringFailure: $message';
}

/// Runs one clustering pass in a background isolate.
///
/// Unlike `EmbeddingIsolate`, which is a long-lived loop draining a backlog,
/// this is a one-shot job: the user opens the cluster view or asks to regroup,
/// the isolate builds one tree and exits. That difference is why there is no
/// control port, pause/resume, or heartbeat here — there is nothing to pause,
/// and a job that has finished should not hold an open database connection.
///
/// The isolate opens its own connection for reading only and relays the finished
/// tree to the main isolate to persist, per the project's rule that only the
/// main isolate's connection writes.
class ClusteringIsolate {
  ClusteringIsolate({AppLogger? logger}) : _logger = logger ?? AppLogger(null);

  final AppLogger _logger;
  Isolate? _isolate;
  ReceivePort? _receivePort;

  bool get isRunning => _isolate != null;

  /// Builds and persists a run for [scope], returning it once saved.
  ///
  /// [maxGroups] is the slider's upper bound. Cost is linear in photo count and
  /// only logarithmic in group count, so raising this is cheap; it is capped
  /// rather than unbounded because every extra split is another group the
  /// labeling job has to pay a vision call for.
  Future<ClusterRun> run({
    required ClusterScope scope,
    required String storagePath,
    required String dbName,
    required RootIsolateToken token,
    int maxGroups = 48,
    int seed = 0x5EED,
    void Function(ClusteringProgress)? onProgress,
  }) async {
    if (_isolate != null) {
      throw ClusteringFailure('a clustering run is already in progress');
    }

    final repository = DatabaseManager.instance.database;
    if (repository == null) {
      throw ClusteringFailure('no main database connection');
    }

    final completer = Completer<ClusterRun>();
    _receivePort = ReceivePort('ClusteringIsolate');

    _receivePort!.listen((data) async {
      if (data is! Map) return;
      switch (data['type']) {
        case 'log':
          _logger.d('[ClusteringIsolate] ${data['message']}');
          break;

        case 'progress':
          onProgress?.call(
            ClusteringProgress(
              ClusteringPhase.values.firstWhere(
                (p) => p.name == data['phase'],
                orElse: () => ClusteringPhase.clustering,
              ),
              current: data['current'] as int? ?? 0,
              total: data['total'] as int? ?? 0,
            ),
          );
          break;

        case 'result':
          // The isolate has done the arithmetic; persisting happens here so
          // the write goes through the main isolate's connection.
          try {
            onProgress?.call(const ClusteringProgress(ClusteringPhase.saving));
            final run = _runFromMessage(data);
            final groups = _groupsFromMessage(run.id, data);
            final membership = (data['membership'] as Map).cast<String, int>();

            final repo = PhotoClusterRepository(repository);
            await repo.saveRun(run, groups, membership);
            await repo.pruneOldRuns();

            if (!completer.isCompleted) completer.complete(run);
          } catch (e, stack) {
            if (!completer.isCompleted) {
              completer.completeError(e, stack);
            }
          } finally {
            await stop();
          }
          break;

        case 'failed':
          if (!completer.isCompleted) {
            completer.completeError(
              ClusteringFailure(data['message'] as String? ?? 'unknown error'),
            );
          }
          await stop();
          break;
      }
    });

    _isolate = await Isolate.spawn(
      _isolateEntry,
      {
        'replyTo': _receivePort!.sendPort,
        'storagePath': storagePath,
        'dbName': dbName,
        'token': token,
        'collectionIds': scope.collectionIds,
        'maxGroups': maxGroups,
        'seed': seed,
      },
      debugName: 'ClusteringIsolate',
      onError: _receivePort!.sendPort,
      onExit: _receivePort!.sendPort,
    );

    return completer.future;
  }

  Future<void> stop() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
  }

  ClusterRun _runFromMessage(Map data) => ClusterRun(
        id: data['runId'] as String,
        scope: ClusterScope.fromKey(data['scopeKey'] as String?),
        createdAt: DateTime.now(),
        photoCount: data['photoCount'] as int,
        maxGroups: data['maxGroups'] as int,
        seed: data['seed'] as int,
        status: ClusterRunStatus.ready,
      );

  List<ClusterGroup> _groupsFromMessage(String runId, Map data) {
    final nodes = (data['nodes'] as List).cast<Map>();
    return [
      for (final node in nodes)
        ClusterGroup(
          runId: runId,
          nodeId: node['nodeId'] as int,
          parentId: node['parentId'] as int?,
          splitRank: node['splitRank'] as int?,
          memberCount: node['memberCount'] as int,
          coherence: (node['coherence'] as num).toDouble(),
          centroid: node['centroid'] as Float32List,
          representatives: (node['representatives'] as List).cast<String>(),
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Worker
  // ---------------------------------------------------------------------------

  static Future<void> _isolateEntry(Map<String, dynamic> cfg) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      cfg['token'] as RootIsolateToken,
    );

    final replyTo = cfg['replyTo'] as SendPort;
    void report(String phase, {int current = 0, int total = 0}) {
      replyTo.send({
        'type': 'progress',
        'phase': phase,
        'current': current,
        'total': total,
      });
    }

    AppDatabase? db;
    try {
      final collectionIds = (cfg['collectionIds'] as List?)?.cast<String>();
      final maxGroups = cfg['maxGroups'] as int;
      final seed = cfg['seed'] as int;

      report(ClusteringPhase.loading.name);
      db = await AppDatabase.create(null, cfg['storagePath'], cfg['dbName']);

      final scope = ClusterScope(collectionIds);
      final loaded =
          await PhotoClusterRepository(db).loadEmbeddingsForScope(scope);
      if (loaded.fileIds.isEmpty) {
        replyTo.send({
          'type': 'failed',
          'message': 'No embedded photos in this selection yet. '
              'Photos are embedded in the background after they are scanned.',
        });
        return;
      }
      // Two photos cannot be split into a meaningful hierarchy, and a
      // single-group view is not worth a run.
      if (loaded.fileIds.length < 3) {
        replyTo.send({
          'type': 'failed',
          'message': 'Not enough photos to group — '
              '${loaded.fileIds.length} in this selection.',
        });
        return;
      }

      report(
        ClusteringPhase.clustering.name,
        current: 0,
        total: maxGroups,
      );

      l2NormalizeRows(loaded.vectors, kClusterEmbeddingDim);
      final tree = buildClusterTree(
        loaded.vectors,
        kClusterEmbeddingDim,
        maxGroups: maxGroups,
        seed: seed,
        onProgress: (leaves, target) => report(
          ClusteringPhase.clustering.name,
          current: leaves,
          total: target,
        ),
      );

      // splitOrder is positional; turning it into a rank per node is what lets
      // the slider replay a prefix of the splits straight from SQL.
      final splitRank = <int, int>{};
      for (var i = 0; i < tree.splitOrder.length; i++) {
        splitRank[tree.splitOrder[i]] = i;
      }

      // Membership is recorded against the deepest leaf only — interior nodes
      // own their descendants' photos via the tree, not via extra rows.
      final membership = <String, int>{};
      for (final node in tree.leavesAt(tree.maxGroups)) {
        for (final index in node.members) {
          membership[loaded.fileIds[index]] = node.id;
        }
      }

      replyTo.send({
        'type': 'result',
        'runId': const Uuid().v4(),
        'scopeKey': ClusterScope(collectionIds).key,
        'photoCount': loaded.fileIds.length,
        'maxGroups': maxGroups,
        'seed': seed,
        'nodes': [
          for (final node in tree.nodes)
            {
              'nodeId': node.id,
              'parentId': node.parentId,
              'splitRank': splitRank[node.id],
              'memberCount': node.size,
              'coherence': node.coherence,
              'centroid': node.centroid,
              // Picked here, where the vectors are still in memory. Doing it
              // later would mean re-reading every member's embedding just to
              // rank it against a centroid already stored alongside it.
              'representatives': [
                for (final index
                    in tree.representatives(node, loaded.vectors, count: 9))
                  loaded.fileIds[index],
              ],
            },
        ],
        'membership': membership,
      });
    } catch (e, stack) {
      replyTo.send({'type': 'failed', 'message': '$e\n$stack'});
    } finally {
      await db?.close();
    }
  }
}
