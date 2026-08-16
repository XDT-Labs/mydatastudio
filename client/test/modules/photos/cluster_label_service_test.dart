import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/services/model_download_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';
import 'package:mydatastudio/modules/photos/services/clustering/cluster_label_service.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClusterLabelService.normalizeLabel', () {
    test('reads the label out of the schema-constrained JSON', () {
      expect(
        ClusterLabelService.normalizeLabel('{"label": "Colosseum"}'),
        'Colosseum',
      );
    });

    // Some models wrap JSON in a markdown fence despite the grammar. Throwing
    // that away would cost a perfectly good label and leave the group as
    // "Group N" forever, since a failed node is not retried.
    test('unwraps a markdown code fence', () {
      expect(
        ClusterLabelService.normalizeLabel('```json\n{"label": "Swans"}\n```'),
        'Swans',
      );
      expect(
        ClusterLabelService.normalizeLabel('```\n{"label": "Youth baseball"}\n```'),
        'Youth baseball',
      );
    });

    test('accepts bare prose when the model ignores the schema', () {
      expect(
        ClusterLabelService.normalizeLabel('Mountain village'),
        'Mountain village',
      );
      expect(
        ClusterLabelService.normalizeLabel('  "Beach days."  '),
        'Beach days',
      );
    });

    test('collapses whitespace and newlines into one header line', () {
      expect(
        ClusterLabelService.normalizeLabel('{"label": "Cathedral\\n  interiors"}'),
        'Cathedral interiors',
      );
    });

    // A refusal or an explanation is not a name. Rejecting it lets the header
    // fall back to "Group N", which is honest, rather than printing a sentence
    // of model commentary as a title.
    test('rejects an answer too long to be a name', () {
      final rambling = 'I am unable to provide a label for these images '
          'because they appear to contain sensitive content that I should '
          'not describe in detail.';
      expect(ClusterLabelService.normalizeLabel(rambling), isNull);
      expect(
        ClusterLabelService.normalizeLabel('{"label": "$rambling"}'),
        isNull,
      );
    });

    test('rejects empty answers', () {
      expect(ClusterLabelService.normalizeLabel(''), isNull);
      expect(ClusterLabelService.normalizeLabel('   '), isNull);
      expect(ClusterLabelService.normalizeLabel('{"label": ""}'), isNull);
      expect(ClusterLabelService.normalizeLabel('{"label": "  "}'), isNull);
    });

    test('strips surrounding quotes without eating internal punctuation', () {
      expect(
        ClusterLabelService.normalizeLabel('"Schönbrunn Palace"'),
        'Schönbrunn Palace',
      );
      expect(
        ClusterLabelService.normalizeLabel('{"label": "Rome, Italy"}'),
        'Rome, Italy',
      );
    });
  });

  _labellingPipelineTests();
  _modelPinningTests();
}

void _labellingPipelineTests() {
  group('ClusterLabelService.labelRun', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late PhotoClusterRepository repo;
    late String runId;

    /// Writes a run whose groups are sized so the labelling order is
    /// unambiguous: node 1 has the most members, then node 2, then node 3.
    Future<List<String>> seedRun() async {
      final collectionId = const Uuid().v4();
      await CollectionRepository(db).addCollection(
        Collection(
          id: collectionId,
          name: 'Photos',
          path: '/photos',
          type: 'file',
          scanner: 'local',
          needsReAuth: false,
          scanStatus: 'idle',
        ),
      );

      final fileRepo = FileDesktopRepository(db);
      final cache = ThumbnailCache(tempDir.path);
      final fileIds = <String>[];

      for (var i = 0; i < 3; i++) {
        final id = 'photo-$i';
        final key = cache.keyFor(collectionId, id);
        await fileRepo.create(
          File(
            id: id,
            name: 'IMG_$i.jpg',
            path: '/photos/IMG_$i.jpg',
            parent: '/photos',
            dateCreated: DateTime(2026, 1, 1),
            dateLastModified: DateTime(2026, 1, 1),
            collectionId: collectionId,
            contentType: 'image/jpeg',
            size: 1,
            isDeleted: false,
            thumbnail: key,
          ),
        );
        // Real bytes on disk: the service skips photos whose thumbnail is
        // missing, so a fixture without one would silently test nothing.
        await cache.writeBytes(key, [0xFF, 0xD8, 0xFF, i]);
        fileIds.add(id);
      }

      runId = const Uuid().v4();
      final run = ClusterRun(
        id: runId,
        scope: const ClusterScope.all(),
        createdAt: DateTime(2026, 1, 1),
        photoCount: 3,
        maxGroups: 3,
        seed: 1,
        status: ClusterRunStatus.ready,
      );

      ClusterGroup node(int id, int? parent, int? rank, int count,
              List<String> reps) =>
          ClusterGroup(
            runId: runId,
            nodeId: id,
            parentId: parent,
            splitRank: rank,
            memberCount: count,
            coherence: 0.8,
            centroid: Float32List(4),
            representatives: reps,
          );

      await repo.saveRun(
        run,
        [
          node(0, null, 0, 3, fileIds),
          node(1, 0, null, 2, [fileIds[0], fileIds[1]]),
          node(2, 0, null, 1, [fileIds[2]]),
        ],
        {fileIds[0]: 1, fileIds[1]: 1, fileIds[2]: 2},
      );
      return fileIds;
    }

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mds_label_test_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;
      repo = PhotoClusterRepository(db);

      MainApp.appDataDirectory.add(tempDir.path);
      MainApp.llmServiceUrl.add('http://127.0.0.1:9999');
      MainApp.llmServiceToken.add('test-token');
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    /// Points the registry's vision model at a cloud provider.
    ///
    /// The read-back matters: an UPDATE that matches no row is not an error in
    /// SQL, so without it this test would pass identically against a registry
    /// with no vision model at all — proving the "missing model" path rather
    /// than the cloud one, which is a different test further down.
    Future<void> makeLabelModelCloud(String group) async {
      await db.execute('UPDATE aichat_models SET "group" = ? WHERE alias = ?',
          [group, kLabelModelAlias]);
      final rows = await db.select(
          'SELECT "group" FROM aichat_models WHERE alias = ?',
          [kLabelModelAlias]);
      expect(rows.single['group'], group,
          reason: 'the row has to exist and say cloud for this to test cloud');
    }

    // The user's photos must never leave the machine for the sake of a caption.
    // If the configured vision model has been repointed at a cloud provider,
    // labelling stops rather than uploading a personal library.
    test('refuses to label through a cloud provider', () async {
      await seedRun();
      await makeLabelModelCloud('gemini');

      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      expect(calls, 0, reason: 'no request may be sent to a cloud model');
      for (final g in (await repo.loadTree(runId))!.allGroups) {
        expect(g.labelStatus, ClusterLabelStatus.pending,
            reason: 'nothing is marked failed — this is a config issue');
      }
    });

    test('refuses when the vision model is missing from the registry',
        () async {
      await seedRun();
      await db.execute('DELETE FROM aichat_models WHERE alias = ?',
          [kLabelModelAlias]);

      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);
      expect(calls, 0, reason: 'cannot verify locality, so send nothing');
    });

    test('labels every group, largest first, and persists as it goes',
        () async {
      await seedRun();
      final labelled = <String>[];
      final sentImageCounts = <int>[];
      final sentModels = <String?>[];

      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sentModels.add(body['model'] as String?);
        final content =
            (body['messages'] as List).first['content'] as List;
        sentImageCounts
            .add(content.where((p) => p['type'] == 'image_url').length);
        labelled.add('call');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '{"label": "Group ${labelled.length}"}'}
              }
            ]
          }),
          200,
        );
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      final tree = await repo.loadTree(runId);
      final byId = {for (final g in tree!.allGroups) g.nodeId: g};

      // Every node got a label, and each carried its own representatives —
      // three for the root, two and one for the children.
      expect(byId[0]!.labelStatus, ClusterLabelStatus.ready);
      expect(byId[1]!.labelStatus, ClusterLabelStatus.ready);
      expect(byId[2]!.labelStatus, ClusterLabelStatus.ready);
      expect(sentImageCounts, [3, 2, 1]);

      // The model is named by this caller, not inherited from the server's
      // default — otherwise where these photos go depends on a setting this
      // code does not control.
      expect(sentModels, everyElement(kLabelModelAlias));

      // Biggest group first: node 0 (3 members), then 1 (2), then 2 (1).
      expect(byId[0]!.label, 'Group 1');
      expect(byId[1]!.label, 'Group 2');
      expect(byId[2]!.label, 'Group 3');
    });

    // A group the model refuses or garbles must not be retried forever, and
    // must not block the groups behind it in the queue.
    test('marks an unusable answer failed and keeps going', () async {
      await seedRun();
      var call = 0;

      final client = MockClient((request) async {
        call++;
        if (call == 1) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': 'I am unable to describe these images because '
                        'they appear to contain sensitive material.'
                  }
                }
              ]
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {'message': {'content': '{"label": "Swans"}'}}
            ]
          }),
          200,
        );
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      final byId = {
        for (final g in (await repo.loadTree(runId))!.allGroups) g.nodeId: g
      };
      expect(byId[0]!.labelStatus, ClusterLabelStatus.failed);
      expect(byId[0]!.label, isNull);
      expect(byId[0]!.displayLabel, 'Group 0', reason: 'falls back honestly');
      expect(byId[1]!.label, 'Swans');
      expect(byId[2]!.label, 'Swans');
    });

    // A Regroup calls cancel() and then labelRun() for the new run. cancel()
    // only sets a flag the loop reads between groups, so the old pass is still
    // inside its HTTP call and _running is still true. The new request used to
    // be dropped on the floor, and the new run's headers stayed "Group N"
    // forever — the symptom that sent us looking here.
    test('a run requested mid-pass is labelled once the pass lets go',
        () async {
      final first = await seedRun();
      expect(first, isNotEmpty);
      final firstRun = runId;

      final labelled = <String>[];
      final client = MockClient((request) async {
        labelled.add(request.url.path);
        return http.Response(
          jsonEncode({
            'choices': [
              {'message': {'content': '{"label": "Named"}'}}
            ]
          }),
          200,
        );
      });

      // Start a pass and, without awaiting it, ask for a second run the way
      // _startLabelling does.
      final firstPass =
          ClusterLabelService.instance.labelRun(repo, firstRun, client: client);
      ClusterLabelService.instance.cancel();
      unawaited(
        ClusterLabelService.instance.labelRun(repo, firstRun, client: client),
      );

      await firstPass;
      // Let the queued pass run to completion.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      while (ClusterLabelService.instance.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final groups = (await repo.loadTree(firstRun))!.allGroups;
      expect(
        groups.every((g) => g.labelStatus != ClusterLabelStatus.pending),
        isTrue,
        reason: 'the queued request has to actually run, not vanish',
      );
    });

    // Thumbnails are generated in the background, so a group can be clustered
    // before its own thumbnails exist. Marking it skipped would condemn it to
    // "Group N" permanently; skipped is for answers that will never change.
    test('a group with no thumbnails yet stays pending for a later pass',
        () async {
      await seedRun();
      await db.execute('UPDATE files SET thumbnail = NULL');

      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      expect(calls, 0, reason: 'there was nothing to show the model');
      for (final g in (await repo.loadTree(runId))!.allGroups) {
        expect(g.labelStatus, ClusterLabelStatus.pending,
            reason: 'retriable once the thumbnails land');
      }
    });

    test('a second pass only retries what is still pending', () async {
      await seedRun();
      await repo.updateLabel(runId, 0, 'Already named', ClusterLabelStatus.ready);

      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({
            'choices': [
              {'message': {'content': '{"label": "Named"}'}}
            ]
          }),
          200,
        );
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      expect(calls, 2, reason: 'the already-named group was skipped');
      final byId = {
        for (final g in (await repo.loadTree(runId))!.allGroups) g.nodeId: g
      };
      expect(byId[0]!.label, 'Already named');
    });

    // The regression that shipped: an aiserver that is simply not running made
    // every group permanently unnamed. Connection refused says nothing about a
    // group's photos, so the status must survive the outage and the pass must
    // stop rather than burning the whole run on a server that is down.
    test('an unreachable server leaves every group pending and stops the pass',
        () async {
      await seedRun();
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        throw http.ClientException('Connection refused');
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      expect(calls, 1, reason: 'stops after the first unreachable response');
      for (final g in (await repo.loadTree(runId))!.allGroups) {
        expect(g.labelStatus, ClusterLabelStatus.pending,
            reason: 'node ${g.nodeId} must stay retryable');
      }
    });

    test('a 5xx is transient and leaves groups pending', () async {
      await seedRun();
      final client = MockClient((_) async => http.Response('boom', 500));

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      for (final g in (await repo.loadTree(runId))!.allGroups) {
        expect(g.labelStatus, ClusterLabelStatus.pending);
      }
    });

    // A 4xx is this request being wrong — too many images for the context, a
    // malformed payload. Retrying sends the identical request, so it is not
    // worth keeping the group in the queue.
    test('a 4xx is permanent and marks the group failed', () async {
      await seedRun();
      final client = MockClient((_) async => http.Response('bad request', 400));

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      final byId = {
        for (final g in (await repo.loadTree(runId))!.allGroups) g.nodeId: g
      };
      expect(byId[0]!.labelStatus, ClusterLabelStatus.failed);
      expect(byId[0]!.displayLabel, 'Group 0');
    });

    test('labels that already landed survive a later outage', () async {
      await seedRun();
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'choices': [
                {'message': {'content': '{"label": "Colosseum"}'}}
              ]
            }),
            200,
          );
        }
        throw http.ClientException('Connection refused');
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      final byId = {
        for (final g in (await repo.loadTree(runId))!.allGroups) g.nodeId: g
      };
      expect(byId[0]!.label, 'Colosseum');
      expect(byId[1]!.labelStatus, ClusterLabelStatus.pending);
      expect(byId[2]!.labelStatus, ClusterLabelStatus.pending);
    });

    // Was asserted as skipped, which was wrong for the same reason as the
    // never-generated case above: a wiped cache gets rebuilt, so the answer
    // changes and the group deserves another pass. Skipped is reserved for
    // answers that will never change.
    test('a group whose thumbnails are gone from disk stays pending',
        () async {
      await seedRun();
      // Wipe the cache: nothing to show the model.
      io.Directory(ThumbnailCache(tempDir.path).rootDir)
          .deleteSync(recursive: true);

      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });

      await ClusterLabelService.instance.labelRun(repo, runId, client: client);

      expect(calls, 0, reason: 'no request without images to send');
      final byId = {
        for (final g in (await repo.loadTree(runId))!.allGroups) g.nodeId: g
      };
      expect(byId[0]!.labelStatus, ClusterLabelStatus.pending);
    });
  });
}

void _modelPinningTests() {
  // The alias used to be repeated at every call site, so upgrading the bundled
  // model left some features pinned to a version nobody downloads any more.
  // Labelling must follow whatever the client actually ships.
  group('label model follows the client default', () {
    test('is the app-wide default alias, not a local literal', () {
      expect(kLabelModelAlias, AppConstants.defaultChatModelAlias);
    });

    test('is the alias the startup downloader fetches', () {
      final downloaded =
          ModelDownloadManager.items.value.map((i) => i.alias).toList();
      expect(downloaded, contains(kLabelModelAlias),
          reason: 'labelling would name a model the client never downloads');
    });
  });
}
