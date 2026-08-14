import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/file_bytes_loader.dart';
import 'package:mydatastudio/modules/files/services/utilities/unreachable_collections.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/credential_codec.dart';
import 'package:mydatastudio/services/embedding_model.dart';
import 'package:mydatastudio/services/embedding_message_handler.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';
import 'package:mydatastudio/services/vault_manager.dart';

/// Extracts and chunks documents that have no current chunk set.
///
/// The fourth background isolate, beside [EmbeddingIsolate],
/// `EmailEmbeddingIsolate` and `FileDescriptionIsolate`. Separate from
/// [EmbeddingIsolate] rather than a branch inside it because extraction is a
/// different order of cost: converting a 40-page PDF is seconds to tens of
/// seconds against milliseconds to read an image, so folding the two together
/// would let one large document stall the photo queue behind it (search plan
/// §18j).
///
/// It depends on **two** server endpoints where the others depend on one:
/// `/util/extract-text` then `/util/embedding`, per chunk. They can be
/// available independently, so the order is deliberate — text is relayed for
/// storage even when no vector could be produced, because a document in
/// `file_chunks_fts` is findable by keyword while a document in neither table
/// is findable by nothing.
class DocumentChunkIsolate {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _controlPort;
  VoidCallback? _vaultListener;
  final SequentialWriteQueue _writeQueue = SequentialWriteQueue();

  Future<void> start(
    String storagePath,
    String dbName,
    RootIsolateToken token,
  ) async {
    if (_isolate != null) return;

    _receivePort = ReceivePort("DocumentChunkIsolate");

    final cfg = <String, dynamic>{
      'replyTo': _receivePort!.sendPort,
      'storagePath': storagePath,
      'dbName': dbName,
      'loggerPort': _receivePort!.sendPort,
      'token': token,
    };

    _isolate = await Isolate.spawn(
      _isolateEntry,
      cfg,
      debugName: 'DocumentChunkIsolate',
    );

    _receivePort?.listen((data) {
      if (data is SendPort) {
        _controlPort = data;
        if (MainApp.llmServiceUrl.hasValue &&
            MainApp.llmServiceUrl.valueOrNull != null) {
          updateUrl(MainApp.llmServiceUrl.valueOrNull!);
        }
        // Same reason as EmbeddingIsolate: this spawns at boot, before login
        // unlocks the vault, so the DEK arrives over the control port and on
        // every later unlock.
        _sendVaultDek();
        _vaultListener = _sendVaultDek;
        VaultManager.instance.unlocked.addListener(_vaultListener!);
      } else if (data is Map) {
        final type = data['type'];
        final logger = AppLogger(null);

        if (type == 'log') {
          final msg = data['message'];
          switch (data['level'] as String) {
            case 'info':
              logger.i('[DocumentChunkIsolate] $msg');
              break;
            case 'error':
              final stData = data['stackTrace'];
              logger.e(
                '[DocumentChunkIsolate] $msg',
                error: data['error'],
                stackTrace:
                    stData == null
                        ? null
                        : (stData is StackTrace
                            ? stData
                            : StackTrace.fromString(stData.toString())),
              );
              break;
            case 'warning':
              logger.w('[DocumentChunkIsolate] $msg');
              break;
            case 'debug':
              logger.d('[DocumentChunkIsolate] $msg');
              break;
          }
        } else if (type == 'embedding') {
          // Serialized for the same reason as the other isolates: a burst of
          // relayed messages issuing unbounded concurrent transactions works
          // against the contention this relay exists to remove.
          _writeQueue.add(() async {
            final repo = DatabaseManager.instance.repository;
            if (repo == null) {
              logger.w(
                '[DocumentChunkIsolate] dropped chunks for id=${data['id']}: '
                'no main database connection',
              );
              return;
            }
            await handleEmbeddingMessage(repo, data, logger);
          });
        } else if (type == 'embeddingFailed') {
          // Only for content the extractor read and could not parse. A file
          // that could not be *reached* has demonstrated nothing, and counting
          // it would spend the retirement budget on an outage.
          _writeQueue.add(() async {
            final repo = DatabaseManager.instance.repository;
            if (repo == null) return;
            await repo.incrementEmbeddingAttempts(data['id'] as String);
          });
        }
      }
    });

    MainApp.llmServiceUrl.listen((url) {
      if (url != null) updateUrl(url);
    });
  }

  void updateUrl(String url) {
    _controlPort?.send({
      'type': 'url',
      'url': url,
      'token': MainApp.llmServiceToken.valueOrNull,
    });
  }

  void pause() => _controlPort?.send({'type': 'pause'});

  void resume() => _controlPort?.send({'type': 'resume'});

  void _sendVaultDek() {
    final dek = VaultManager.instance.dek;
    if (dek == null) {
      _controlPort?.send({'type': 'vaultLocked'});
      return;
    }
    _controlPort?.send({'type': 'vaultDek', 'dek': dek});
  }

  static Future<void> _isolateEntry(Map<String, dynamic> cfg) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      cfg['token'] as RootIsolateToken,
    );

    final String storagePath = cfg['storagePath'];
    final String dbName = cfg['dbName'];
    final logger = AppLogger(cfg['loggerPort'] as SendPort?);
    final replyTo = cfg['replyTo'] as SendPort;

    final controlPort = ReceivePort();
    replyTo.send(controlPort.sendPort);

    String? serviceUrl;
    String? serviceToken;
    bool isPaused = false;

    controlPort.listen((message) {
      if (message is! Map) return;
      switch (message['type']) {
        case 'url':
          serviceUrl = message['url'];
          serviceToken = message['token'];
          logger.d('Python service URL updated: $serviceUrl');
          break;
        case 'vaultDek':
          CredentialCodec.installIsolateVault(message['dek'] as Uint8List?);
          break;
        case 'vaultLocked':
          CredentialCodec.clearIsolateVault();
          break;
        case 'pause':
          isPaused = true;
          logger.d('DocumentChunkIsolate paused during active sync');
          break;
        case 'resume':
          isPaused = false;
          logger.d('DocumentChunkIsolate resumed after sync completion');
          break;
      }
    });

    logger.i('DocumentChunkIsolate starting loop');

    final db = await AppDatabase.create(null, storagePath, dbName);
    final repo = DatabaseRepository(db);

    await Future.delayed(const Duration(seconds: 5));

    // Smaller than the image batch: a document can be tens of seconds of work
    // and each one issues a chunk-count of embedding calls, so a large batch
    // would hold the isolate far past the next pause check.
    const kBatchSize = 5;
    final unreachable = UnreachableCollections();

    while (true) {
      try {
        if (isPaused) {
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }
        if (serviceUrl == null) {
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }

        final pending = await repo.getFilesWithMissingChunks(
          limit: kBatchSize,
          excludeCollections: unreachable.deferred(),
        );
        if (pending.isEmpty) {
          await Future.delayed(const Duration(seconds: 60));
          continue;
        }

        logger.i('Extracting ${pending.length} documents');
        for (final file in pending) {
          if (isPaused) break;
          await _processDocument(
            file,
            repo,
            serviceUrl!,
            serviceToken,
            replyTo,
            unreachable,
            logger,
          );
        }
        await Future.delayed(const Duration(seconds: 2));
      } catch (e, stackTrace) {
        logger.e('DocumentChunkIsolate loop error: $e', stackTrace: stackTrace);
        await Future.delayed(const Duration(seconds: 30));
      }
    }
  }

  static Future<void> _processDocument(
    File file,
    DatabaseRepository repo,
    String serviceUrl,
    String? serviceToken,
    SendPort replyTo,
    UnreachableCollections unreachable,
    AppLogger logger,
  ) async {
    final loaded = await FileBytesLoader.loadDetailed(file, repo, logger);
    if (!loaded.ok) {
      if (loaded.permanent) {
        // This file has no bytes and never will — a Google Doc, say (§18k).
        // Deferring the collection for it would stall every *other* document
        // in that source behind a condition that has nothing to do with the
        // source being reachable. Spend an attempt instead, so it retires on
        // its own schedule and stops being offered.
        logger.w('Permanently unreadable, retiring: ${file.name}');
        replyTo.send({'type': 'embeddingFailed', 'id': file.id});
        return;
      }
      // Unread, not unreadable: an unmounted volume or an expired token. The
      // file keeps its full retry budget and the whole collection backs off,
      // so a laptop away from its NAS does not retire an archive.
      unreachable.recordFailure(file.collectionId);
      return;
    }
    final bytes = loaded.bytes!;
    unreachable.recordSuccess(file.collectionId);

    final extraction = await _extract(
      bytes,
      // An exported Workspace document is DOCX or XLSX regardless of what it
      // is called in Drive, and those share a ZIP signature — so the loader's
      // hint, not the file's name, is what lets the server route it (§18k).
      loaded.filenameHint ?? file.name,
      serviceUrl,
      serviceToken,
      logger,
    );
    if (extraction == null) return;

    if (extraction.permanentFailure) {
      // Content we recognised and could not parse — measured at roughly a
      // fifth of this archive's documents (§18a-1), so this path is ordinary
      // rather than exceptional. Counting it lets the file eventually retire
      // instead of being re-read on every pass forever.
      logger.w('Unparseable document ${file.name}: ${extraction.detail}');
      replyTo.send({'type': 'embeddingFailed', 'id': file.id});
      return;
    }

    final chunks = extraction.chunks;
    if (chunks.isEmpty) return;

    // Vectors are optional, and their absence is not an error. A gated
    // document (§18a-2) is deliberately un-embedded, and a missing embedding
    // model is a temporary state the text should not wait for.
    final vectors = <List<double>>[];
    if (!extraction.gated) {
      for (final chunk in chunks) {
        final vector = await _embed(
          chunk['text'] as String,
          serviceUrl,
          serviceToken,
          logger,
        );
        if (vector == null) {
          // Stop at the first failure rather than leaving a hole: the write
          // pairs vectors to chunks by position, so a short list must be a
          // prefix. The text still lands; the tail is embedded on a later
          // pass once the model is back.
          logger.w(
            'Embedding stopped after ${vectors.length}/${chunks.length} '
            'chunks of ${file.name}; storing text now, vectors later',
          );
          break;
        }
        vectors.add(vector);
      }
    }

    replyTo.send({
      'type': 'embedding',
      'table': 'file_chunks',
      'id': file.id,
      'chunks': chunks,
      'embeddings': vectors,
    });
  }

  /// POSTs the document's bytes to `/util/extract-text`.
  ///
  /// Returns null when the failure is the *service* rather than the file, so
  /// the caller leaves the retry budget alone.
  static Future<_Extraction?> _extract(
    List<int> bytes,
    String filename,
    String serviceUrl,
    String? serviceToken,
    AppLogger logger,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$serviceUrl/util/extract-text'),
        headers: {
          'Content-Type': 'application/json',
          ...aiServerAuthHeaders(serviceToken),
        },
        body: jsonEncode({
          'file_base64': base64Encode(bytes),
          'filename': filename,
        }),
      );

      // 415 is a format we decline to index — never worth retrying, and not a
      // failure of this file's content either, so it costs no attempt. 422 is
      // content we recognised and could not parse, which does.
      if (response.statusCode == 415) {
        logger.d('Skipping unsupported document $filename');
        return null;
      }

      // 503 means the *server* cannot read this format yet — a missing
      // pdfium, an undownloaded model. The document is fine and will extract
      // once the dependency lands, so this must cost no attempt: five of these
      // would retire the file permanently before the feature that reads it
      // ever ships. Returning null is exactly the unreachable-file path.
      if (response.statusCode == 503) {
        logger.d('Extraction unavailable for $filename; will retry later');
        return null;
      }
      if (response.statusCode == 422) {
        return _Extraction.failed(response.body);
      }
      if (response.statusCode != 200) {
        logger.e('extract-text error ${response.statusCode}: ${response.body}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return _Extraction(
        chunks: (data['chunks'] as List).cast<Map<String, dynamic>>(),
        gated: data['gated'] as bool? ?? false,
      );
    } catch (e) {
      logger.e('Error calling extract-text: $e');
      return null;
    }
  }

  static Future<List<double>?> _embed(
    String text,
    String serviceUrl,
    String? serviceToken,
    AppLogger logger,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$serviceUrl/util/embedding'),
        headers: {
          'Content-Type': 'application/json',
          ...aiServerAuthHeaders(serviceToken),
        },
        body: jsonEncode({
          'model_name': EmbeddingModel.modelName,
          'texts': [text],
        }),
      );
      if (response.statusCode != 200) {
        logger.e('Embedding error ${response.statusCode}: ${response.body}');
        return null;
      }
      final rows = (jsonDecode(response.body))['embeddings'];
      if (rows is! List || rows.isEmpty) return null;
      final row = rows.first;
      if (row is! List) return null;
      // Not .cast<double>(): whole-number components decode as int and cast
      // throws on them lazily, far from here.
      return row.map((e) => (e as num).toDouble()).toList();
    } catch (e) {
      logger.e('Error calling embedding service: $e');
      return null;
    }
  }

  Future<void> stop() async {
    if (_vaultListener != null) {
      VaultManager.instance.unlocked.removeListener(_vaultListener!);
      _vaultListener = null;
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _controlPort = null;
    _receivePort?.close();
    _receivePort = null;
  }
}

class _Extraction {
  final List<Map<String, dynamic>> chunks;
  final bool gated;
  final bool permanentFailure;
  final String? detail;

  const _Extraction({required this.chunks, required this.gated})
    : permanentFailure = false,
      detail = null;

  const _Extraction.failed(String this.detail)
    : chunks = const [],
      gated = false,
      permanentFailure = true;
}
