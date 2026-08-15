import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_repository.dart';

const String _kLabelPrompt = '''
These images all belong to one group in a personal photo library.
Give the group a short name — 2 to 4 words — describing what the images have
in common: the subject, place, or kind of image. Prefer the specific over the
generic when the images support it ("Colosseum", "Youth baseball") and stay
general when they do not ("Beach days", "Screenshots"). Do not mention the
number of photos, the word "group", or the word "photos".
''';

const Map<String, Object> _kLabelSchema = {
  'type': 'object',
  'properties': {
    'label': {'type': 'string'},
  },
  'required': ['label'],
};

/// What came back from one labelling request.
///
/// The distinction that matters is permanent versus transient. A model that
/// answers unusably will answer unusably again, so that group is done being
/// tried; a server that cannot be reached says nothing about the group at all,
/// and marking it failed would turn a restartable outage into permanently
/// unnamed groups.
enum LabelOutcome { ok, unusable, unreachable }

/// Generates a name for each cluster group by showing a vision model the
/// group's most central photos.
///
/// Runs on the main isolate rather than in a worker, unlike the embedding and
/// description isolates. Those grind through an unbounded backlog, decoding
/// full-size originals; this walks a bounded set of nodes and reads
/// already-generated thumbnails a few kilobytes each, so the only main-thread
/// cost is base64-encoding them. The long part is the HTTP wait, which is
/// async I/O and blocks nothing.
///
/// Labels arrive one at a time and are written as they land. `generation_lock`
/// in the aiserver serialises decoding anyway, so there is nothing to gain by
/// firing these in parallel — and a whole-run wait would leave every header
/// reading "Group N" for minutes with no sign of progress.
class ClusterLabelService {
  static final ClusterLabelService _instance = ClusterLabelService._();
  static ClusterLabelService get instance => _instance;

  ClusterLabelService._();

  final AppLogger logger = AppLogger(null);

  /// Fires after each label lands so the view can refresh that header.
  final StreamController<String> _labelled = StreamController<String>.broadcast();
  Stream<String> get onLabelled => _labelled.stream;

  bool _running = false;
  bool _cancelled = false;

  bool get isRunning => _running;

  /// Names every unlabelled group in [runId], largest group first.
  ///
  /// Biggest-first because group size is the best available proxy for how
  /// likely the user is to be looking at it: a large group is a leaf at more
  /// slider positions than a small one, and it dominates the screen at every
  /// position where it appears.
  ///
  /// Safe to call repeatedly — nodes already resolved are skipped, so a second
  /// pass only picks up what previously failed or was interrupted.
  Future<void> labelRun(
    PhotoClusterRepository repo,
    String runId, {
    http.Client? client,
  }) async {
    if (_running) return;
    _running = true;
    _cancelled = false;

    final owned = client == null;
    final httpClient = client ?? http.Client();

    try {
      final tree = await repo.loadTree(runId);
      if (tree == null) return;

      final pending = tree.allGroups
          .where((g) => g.labelStatus == ClusterLabelStatus.pending)
          .toList()
        ..sort((a, b) => b.memberCount.compareTo(a.memberCount));

      for (final group in pending) {
        if (_cancelled) break;

        final serviceUrl = MainApp.llmServiceUrl.valueOrNull;
        if (serviceUrl == null) {
          logger.d('ClusterLabelService: no aiserver yet, stopping');
          break;
        }

        final images = await _loadRepresentativeImages(repo, runId, group);
        if (images.isEmpty) {
          // No readable thumbnails — nothing to look at, and retrying next
          // pass would fail identically until the thumbnails are generated.
          await repo.updateLabel(
            runId, group.nodeId, null, ClusterLabelStatus.skipped);
          continue;
        }

        final result = await _askForLabel(
          images,
          serviceUrl,
          MainApp.llmServiceToken.valueOrNull,
          httpClient,
        );

        switch (result.outcome) {
          case LabelOutcome.ok:
            await repo.updateLabel(
              runId, group.nodeId, result.label, ClusterLabelStatus.ready);

          case LabelOutcome.unusable:
            // The model answered, and the answer is not a name — a refusal, or
            // prose too long for a header. Permanent: asking again gets the
            // same thing. Marked failed so one awkward group cannot be retried
            // ahead of every other group on every later pass, and the header
            // falls back to "Group N", which is honest about not knowing.
            await repo.updateLabel(
              runId, group.nodeId, null, ClusterLabelStatus.failed);

          case LabelOutcome.unreachable:
            // The aiserver is down, still starting, or wedged. Nothing is wrong
            // with this group, so its status is left alone and the whole pass
            // stops: the next 94 requests would fail identically, and burning
            // through them would mark the entire run failed over an outage
            // that resolves itself when the server comes back.
            logger.w(
              'ClusterLabelService: aiserver unreachable, stopping after '
              '${group.nodeId} — groups stay pending for the next pass',
            );
            return;
        }
        _labelled.add(runId);
      }
    } catch (e, stack) {
      logger.e('ClusterLabelService: labelling failed',
          error: e, stackTrace: stack);
    } finally {
      if (owned) httpClient.close();
      _running = false;
    }
  }

  /// Stops after the in-flight label. Called when the user switches to a
  /// different run, whose labels matter more than finishing this one.
  void cancel() => _cancelled = true;

  /// Base64 JPEGs for a group's representatives.
  ///
  /// Reads the on-disk thumbnail cache rather than the originals: the bytes are
  /// already small and already JPEG, so there is no decode of a 5 MB HEIC and
  /// no `/util/thumbnail` round trip. Photos whose thumbnail is a remote Drive
  /// URL or simply missing are skipped — a group has far more members than the
  /// handful needed, so losing a few costs nothing.
  Future<List<String>> _loadRepresentativeImages(
    PhotoClusterRepository repo,
    String runId,
    ClusterGroup group,
  ) async {
    var ids = group.representatives;
    if (ids.isEmpty) {
      // Runs built before representatives were stored, or a node whose
      // representatives were pruned with their files.
      ids = (await repo.fileIdsUnder(runId, group.nodeId)).take(9).toList();
    }
    if (ids.isEmpty) return const [];

    final root = MainApp.appDataDirectory.valueOrNull;
    if (root == null) return const [];
    final cache = ThumbnailCache(root);

    final thumbnails = await repo.thumbnailKeysFor(ids);
    final images = <String>[];

    for (final id in ids) {
      final key = thumbnails[id];
      if (key == null || !ThumbnailCache.isCacheKey(key)) continue;
      final file = cache.fileForKey(key);
      if (!file.existsSync()) continue;
      try {
        images.add(base64Encode(await file.readAsBytes()));
      } on io.IOException catch (e) {
        logger.w('ClusterLabelService: unreadable thumbnail for $id: $e');
      }
    }
    return images;
  }

  Future<({LabelOutcome outcome, String? label})> _askForLabel(
    List<String> base64Images,
    String serviceUrl,
    String? serviceToken,
    http.Client client,
  ) async {
    try {
      final response = await client
          .post(
            Uri.parse('$serviceUrl/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              ...aiServerAuthHeaders(serviceToken),
            },
            body: jsonEncode({
              // No 'model': the server defaults to the vision-capable model
              // configured as DEFAULT_MODEL_ALIAS, same as the description
              // isolate relies on.
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    for (final image in base64Images)
                      {
                        'type': 'image_url',
                        'image_url': {'url': 'data:image/jpeg;base64,$image'},
                      },
                    {'type': 'text', 'text': _kLabelPrompt},
                  ],
                },
              ],
              'stream': false,
              'response_format': {
                'type': 'json_object',
                'schema': _kLabelSchema,
              },
            }),
          )
          // Several images in one request on a local model is genuinely slow.
          // Generous headroom, not a normal-case bound — but an unresponsive
          // aiserver must not stall the whole queue forever.
          .timeout(const Duration(minutes: 5));

      if (response.statusCode != 200) {
        logger.w('ClusterLabelService: aiserver ${response.statusCode}');
        // 5xx is the server failing at something it should manage — a model
        // still loading, an out-of-memory decode — and is worth retrying. 4xx
        // means this request is wrong (too many images for the context, a bad
        // payload) and will be just as wrong next time.
        return (
          outcome: response.statusCode >= 500
              ? LabelOutcome.unreachable
              : LabelOutcome.unusable,
          label: null,
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      final message = choices == null || choices.isEmpty
          ? null
          : (choices.first as Map<String, dynamic>)['message'];
      final content = message is Map ? message['content'] as String? : null;
      final label = content == null ? null : normalizeLabel(content);

      return label == null || label.isEmpty
          ? (outcome: LabelOutcome.unusable, label: null)
          : (outcome: LabelOutcome.ok, label: label);
    } on http.ClientException catch (e) {
      // Connection refused: the aiserver is not up. The embedding and
      // description isolates treat this as "wait and try again", and so must
      // this — a dead server is not a statement about any group's photos.
      logger.w('ClusterLabelService: aiserver unreachable: $e');
      return (outcome: LabelOutcome.unreachable, label: null);
    } on io.SocketException catch (e) {
      logger.w('ClusterLabelService: aiserver unreachable: $e');
      return (outcome: LabelOutcome.unreachable, label: null);
    } on TimeoutException catch (e) {
      logger.w('ClusterLabelService: label request timed out: $e');
      return (outcome: LabelOutcome.unreachable, label: null);
    } catch (e) {
      logger.w('ClusterLabelService: label request failed: $e');
      return (outcome: LabelOutcome.unusable, label: null);
    }
  }

  /// Pulls a usable label out of the model's answer.
  ///
  /// The schema constrains generation to JSON, but a refusal or a model that
  /// ignores the grammar can still come back as bare prose, so plain text is
  /// accepted as a fallback rather than thrown away. Length is capped because
  /// a header has one line: anything longer is the model explaining itself,
  /// which is not a name.
  static String? normalizeLabel(String content) {
    var text = content.trim();

    // ```json … ``` fences, which some models add despite the schema.
    if (text.startsWith('```')) {
      final firstBreak = text.indexOf('\n');
      if (firstBreak != -1) text = text.substring(firstBreak + 1);
      if (text.endsWith('```')) {
        text = text.substring(0, text.length - 3);
      }
      text = text.trim();
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['label'] is String) {
        text = (decoded['label'] as String).trim();
      }
    } on FormatException {
      // Not JSON — fall through and treat the text itself as the label.
    }

    text = text.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    text = text.replaceAll(RegExp(r'^["“”]+|["“”.]+$'), '').trim();

    if (text.isEmpty || text.length > 60) return null;
    return text;
  }
}
