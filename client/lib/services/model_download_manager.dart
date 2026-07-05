import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/repositories/aichat_model_repository.dart';

/// Local-only checks (`/util/model-status`) should return near-instantly —
/// bound them so a hung connection surfaces as a fast error instead of an
/// item sitting in "checking" forever.
const _statusCheckTimeout = Duration(seconds: 15);

/// Bounds only the initial response to `/util/download-model` (the request
/// hitting the server and starting to stream), not the download itself —
/// multi-gigabyte downloads legitimately take a long time once under way.
const _downloadConnectTimeout = Duration(seconds: 30);

enum ModelDownloadStatus { pending, checking, downloading, complete, error }

/// One model (or model file pair) tracked by [ModelDownloadManager].
class ModelDownloadItem {
  ModelDownloadItem({
    required this.alias,
    required this.label,
    required this.hfRepo,
    this.filename,
    this.mmprojFilename,
  });

  final String alias;
  final String label;
  final String hfRepo;

  /// Single GGUF filename to download, or null to download the full repo
  /// snapshot (multi-file Transformers models, e.g. the embedding model).
  final String? filename;

  /// Optional second GGUF file (e.g. a vision projector) downloaded after [filename].
  final String? mmprojFilename;

  ModelDownloadStatus status = ModelDownloadStatus.pending;
  double progress = 0.0;
  double downloadedMb = 0.0;
  double totalMb = 0.0;
  String? error;

  String? resolvedModelPath;
  String? resolvedMmprojPath;
}

/// Downloads the app's default local models (chat model + embedding model) in
/// the background after the AI service starts, so app startup never blocks on
/// multi-gigabyte downloads. The AIChat screen watches [items] and [isReady]
/// to show per-file progress and a retry button until everything is ready.
///
/// Every check goes through the aiserver's `/util/model-status` endpoint,
/// which only looks at local disk — so a prior successful download is
/// recognized instantly on the next launch without re-hitting HuggingFace.
class ModelDownloadManager {
  ModelDownloadManager._();

  static final ModelDownloadManager instance = ModelDownloadManager._();

  static final ValueNotifier<List<ModelDownloadItem>> items = ValueNotifier([
    ModelDownloadItem(
      alias: 'gemma4:12b',
      label: 'Gemma 4 12B (chat model)',
      hfRepo: 'ggml-org/gemma-4-12B-it-GGUF',
      filename: 'gemma-4-12B-it-Q4_K_M.gguf',
      mmprojFilename: 'mmproj-gemma-4-12B-it-Q8_0.gguf',
    ),
    ModelDownloadItem(
      alias: 'qwen3-vl-embedding:2b',
      label: 'Qwen 3 VL Embedding (file & photo search)',
      hfRepo: 'Qwen/Qwen3-VL-Embedding-2B',
    ),
  ]);

  static final ValueNotifier<bool> isReady = ValueNotifier(false);

  final AppLogger _logger = AppLogger(null);
  bool _running = false;

  bool get _allComplete =>
      items.value.every((i) => i.status == ModelDownloadStatus.complete);

  /// [items] holds a list whose elements are mutated in place, so reassigning
  /// the same reference wouldn't notify listeners — rewrap it in a new list.
  void _notifyItemsChanged() {
    items.value = List<ModelDownloadItem>.of(items.value);
  }

  /// Kicks off (or resumes) downloading. Safe to call repeatedly — a no-op
  /// while a run is already in progress. Never throws; failures are recorded
  /// per-item in [items] instead.
  Future<void> start() async {
    if (_running) {
      _logger.d('[ModelDownload] start() called while already running — skipping.');
      return;
    }
    _running = true;
    _logger.i('[ModelDownload] Starting model check/download.');
    try {
      await _runPending();
      _logger.i(
        '[ModelDownload] Run finished. isReady=${isReady.value} '
        'statuses=${items.value.map((i) => '${i.alias}:${i.status.name}').join(', ')}',
      );
    } catch (e, stack) {
      // Guarantees no item is left stuck silently in pending/checking forever —
      // surface it as a per-item error with a working Retry button instead.
      _logger.e('[ModelDownload] Unexpected failure in _runPending: $e', error: e, stackTrace: stack);
      for (final item in items.value) {
        if (item.status != ModelDownloadStatus.complete) {
          item.status = ModelDownloadStatus.error;
          item.error = 'Unexpected error: $e';
        }
      }
      _notifyItemsChanged();
    } finally {
      _running = false;
    }
  }

  /// Resets failed items to pending and re-runs just those.
  Future<void> retry() async {
    for (final item in items.value) {
      if (item.status == ModelDownloadStatus.error) {
        item.status = ModelDownloadStatus.pending;
        item.error = null;
      }
    }
    _notifyItemsChanged();
    await start();
  }

  Future<void> _runPending() async {
    final serviceUrl = MainApp.llmServiceUrl.valueOrNull;
    if (serviceUrl == null) {
      _logger.w('[ModelDownload] AI service URL not available yet — aborting this run.');
      return;
    }

    final db = DatabaseManager.instance.database;
    if (db == null) {
      _logger.w('[ModelDownload] Database not available yet — aborting this run.');
      return;
    }
    final repo = AichatModelRepository(db);
    final hfToken = await _lookupHfToken(db);

    final client = http.Client();
    try {
      for (final item in items.value) {
        if (item.status == ModelDownloadStatus.complete) continue;
        _logger.i('[ModelDownload] Resolving ${item.alias} (${item.hfRepo})...');
        await _resolveItem(client, serviceUrl, hfToken, repo, item);
      }
    } finally {
      client.close();
    }

    isReady.value = _allComplete;
  }

  Future<void> _resolveItem(
    http.Client client,
    String serviceUrl,
    String? hfToken,
    AichatModelRepository repo,
    ModelDownloadItem item,
  ) async {
    item.status = ModelDownloadStatus.checking;
    _notifyItemsChanged();

    final existingModelPath = await _checkStatus(
      client: client,
      serviceUrl: serviceUrl,
      hfRepo: item.hfRepo,
      filename: item.filename,
    );

    if (existingModelPath != null) {
      item.resolvedModelPath = existingModelPath;
    } else {
      item.status = ModelDownloadStatus.downloading;
      item.progress = 0;
      item.downloadedMb = 0;
      item.totalMb = 0;
      _notifyItemsChanged();

      final downloadedPath = await _downloadFile(
        client: client,
        serviceUrl: serviceUrl,
        hfRepo: item.hfRepo,
        filename: item.filename,
        hfToken: hfToken,
        item: item,
      );
      if (downloadedPath == null) {
        item.status = ModelDownloadStatus.error;
        _notifyItemsChanged();
        return;
      }
      item.resolvedModelPath = downloadedPath;
    }

    if (item.mmprojFilename != null) {
      final existingMmprojPath = await _checkStatus(
        client: client,
        serviceUrl: serviceUrl,
        hfRepo: item.hfRepo,
        filename: item.mmprojFilename,
      );

      if (existingMmprojPath != null) {
        item.resolvedMmprojPath = existingMmprojPath;
      } else {
        item.progress = 0;
        item.downloadedMb = 0;
        item.totalMb = 0;
        item.status = ModelDownloadStatus.downloading;
        _notifyItemsChanged();

        final downloadedMmprojPath = await _downloadFile(
          client: client,
          serviceUrl: serviceUrl,
          hfRepo: item.hfRepo,
          filename: item.mmprojFilename,
          hfToken: hfToken,
          item: item,
        );
        if (downloadedMmprojPath == null) {
          item.status = ModelDownloadStatus.error;
          _notifyItemsChanged();
          return;
        }
        item.resolvedMmprojPath = downloadedMmprojPath;
      }
    }

    await _markComplete(repo, item);
  }

  Future<void> _markComplete(
    AichatModelRepository repo,
    ModelDownloadItem item,
  ) async {
    var model = await repo.getByAlias(item.alias);
    model ??= await repo.create(
      alias: item.alias,
      group: item.filename == null ? 'embedding' : 'local',
      name: item.label,
      hfRepo: item.hfRepo,
      type: item.filename == null ? 'transformers' : 'gguf',
    );
    if (item.filename != null) {
      await repo.setLocalPath(model.id, item.resolvedModelPath!, item.resolvedMmprojPath);
    } else {
      await repo.setEnabled(model.id, true);
    }
    item.status = ModelDownloadStatus.complete;
    item.progress = 1.0;
    _notifyItemsChanged();
  }

  Future<String?> _lookupHfToken(AppDatabase db) async {
    final rows = await db
        .select("SELECT api_key FROM providers WHERE service = 'huggingface' LIMIT 1")
        .timeout(_statusCheckTimeout);
    if (rows.isEmpty) return null;
    final key = (rows.first['api_key'] as String? ?? '').trim();
    return key.isEmpty ? null : key;
  }

  /// Returns the resolved local path if already downloaded, else null.
  /// Local-disk-only on the server side — never triggers a download.
  Future<String?> _checkStatus({
    required http.Client client,
    required String serviceUrl,
    required String hfRepo,
    required String? filename,
  }) async {
    try {
      final response = await client
          .post(
            Uri.parse('$serviceUrl/util/model-status'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'model_name': hfRepo, 'filename': filename}),
          )
          .timeout(_statusCheckTimeout);
      if (response.statusCode != 200) {
        _logger.w('[ModelDownload] model-status for $hfRepo/$filename returned ${response.statusCode}');
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['exists'] == true) return data['model_path'] as String?;
      return null;
    } catch (e) {
      _logger.w('[ModelDownload] model-status check failed for $hfRepo/$filename: $e');
      return null;
    }
  }

  /// Downloads a single file (filename != null) or a full repo snapshot
  /// (filename == null) via the AI server's SSE endpoint, updating [item]'s
  /// progress fields as events arrive. Returns the local path on success.
  Future<String?> _downloadFile({
    required http.Client client,
    required String serviceUrl,
    required String hfRepo,
    required String? filename,
    required String? hfToken,
    required ModelDownloadItem item,
  }) async {
    final request = http.Request(
      'POST',
      Uri.parse('$serviceUrl/util/download-model'),
    );
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'model_name': hfRepo,
      'filename': filename,
      if (hfToken != null) 'hf_token': hfToken,
    });

    _logger.i('[ModelDownload] Requesting download: $hfRepo/${filename ?? '(snapshot)'}');

    final http.StreamedResponse streamed;
    try {
      streamed = await client.send(request).timeout(_downloadConnectTimeout);
    } catch (e) {
      _logger.e('[ModelDownload] Could not reach AI service for $hfRepo/$filename: $e');
      item.error = 'Could not reach AI service: $e';
      return null;
    }
    if (streamed.statusCode != 200) {
      _logger.e('[ModelDownload] Download request for $hfRepo/$filename failed with ${streamed.statusCode}');
      item.error = 'Download failed (${streamed.statusCode})';
      return null;
    }

    String? resultPath;
    final buffer = StringBuffer();
    try {
      await streamed.stream.transform(const Utf8Decoder()).forEach((chunk) {
        buffer.write(chunk);
        final lines = buffer.toString().split('\n');
        buffer
          ..clear()
          ..write(lines.last);

        for (final line in lines.sublist(0, lines.length - 1)) {
          if (!line.startsWith('data: ')) continue;
          final event = jsonDecode(line.substring(6)) as Map<String, dynamic>;
          final status = event['status'] as String;

          if (status == 'downloading') {
            item.progress = (event['progress'] as num).toDouble();
            item.downloadedMb = (event['downloaded_mb'] as num).toDouble();
            item.totalMb = (event['total_mb'] as num).toDouble();
            _notifyItemsChanged();
          } else if (status == 'complete') {
            resultPath = event['model_path'] as String? ?? '';
            if (resultPath!.isEmpty) resultPath = null;
            _logger.i('[ModelDownload] Completed $hfRepo/$filename -> $resultPath');
          } else if (status == 'error') {
            item.error = event['message'] as String? ?? 'Download failed';
            _logger.e('[ModelDownload] Server reported error for $hfRepo/$filename: ${item.error}');
          }
        }
      });
    } catch (e) {
      // A network interruption mid-stream must only fail this item — letting
      // it escape would bubble up to start()'s catch-all, which marks every
      // other pending/downloading item as errored too.
      _logger.e('[ModelDownload] Stream interrupted for $hfRepo/$filename: $e');
      item.error = 'Connection interrupted: $e';
      return null;
    }
    return resultPath;
  }
}
