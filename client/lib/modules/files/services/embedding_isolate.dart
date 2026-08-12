import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/services/utilities/file_bytes_loader.dart';
import 'package:mydatastudio/modules/files/services/utilities/vision_image.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/embedding_model.dart';
import 'package:mydatastudio/services/credential_codec.dart';
import 'package:mydatastudio/services/embedding_message_handler.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';
import 'package:mydatastudio/services/vault_manager.dart';

class EmbeddingIsolate {
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

    _receivePort = ReceivePort("EmbeddingIsolate");

    Map<String, dynamic> cfg = {
      'replyTo': _receivePort!.sendPort,
      'storagePath': storagePath,
      'dbName': dbName,
      'loggerPort': _receivePort!.sendPort,
      'token': token,
    };

    _isolate = await Isolate.spawn(
      _isolateEntry,
      cfg,
      debugName: 'EmbeddingIsolate',
    );

    _receivePort?.listen((data) {
      if (data is SendPort) {
        _controlPort = data;
        // Send initial URL if available
        if (MainApp.llmServiceUrl.hasValue &&
            MainApp.llmServiceUrl.valueOrNull != null) {
          updateUrl(MainApp.llmServiceUrl.valueOrNull!);
        }
        // Push the vault DEK now (if already unlocked) and on every later unlock.
        // The isolate spawns at app boot, before login unlocks the vault, so the
        // DEK arrives over the control port — the same channel as the aiserver
        // token (AUDIT M2 phase 4).
        _sendVaultDek();
        _vaultListener = _sendVaultDek;
        VaultManager.instance.unlocked.addListener(_vaultListener!);
      } else if (data is Map) {
        final type = data['type'];
        final msg = data['message'];
        final logger = AppLogger(null);

        if (type == 'log') {
          final level = data['level'] as String;
          switch (level) {
            case 'info':
              logger.i('[EmbeddingIsolate] $msg');
              break;
            case 'error':
              final stData = data['stackTrace'];
              final st =
                  stData == null
                      ? null
                      : (stData is StackTrace
                          ? stData
                          : StackTrace.fromString(stData.toString()));
              logger.e(
                '[EmbeddingIsolate] $msg',
                error: data['error'],
                stackTrace: st,
              );
              break;
            case 'warning':
              logger.w('[EmbeddingIsolate] $msg');
              break;
            case 'debug':
              logger.d('[EmbeddingIsolate] $msg');
              break;
          }
        } else if (type == 'embedding') {
          // Queued rather than fired-and-forgotten: unbounded concurrent
          // db.transaction calls from a burst of relayed messages work
          // against the same contention this relay exists to remove.
          _writeQueue.add(() async {
            final repo = DatabaseManager.instance.repository;
            if (repo == null) {
              logger.w(
                '[EmbeddingIsolate] dropped embedding for id=${data['id']}: '
                'no main database connection',
              );
              return;
            }
            await handleEmbeddingMessage(repo, data, logger);
          });
        } else if (type == 'embeddingFailed') {
          // Records a rejected-bytes failure so an image that can never
          // succeed eventually drops out of getFilesWithMissingEmbeddings
          // instead of being retried forever — see maxEmbeddingAttempts. Only
          // sent when the file was readable; an unreachable file is retried
          // without cost.
          _writeQueue.add(() async {
            final repo = DatabaseManager.instance.repository;
            if (repo == null) return;
            await repo.incrementEmbeddingAttempts(data['id'] as String);
          });
        }
      }
    });

    // Listen for URL changes
    MainApp.llmServiceUrl.listen((url) {
      if (url != null) {
        updateUrl(url);
      }
    });
  }

  void updateUrl(String url) {
    // Ship the bearer token alongside the URL — it's fixed per server spawn and
    // the worker isolate can't read MainApp statics directly.
    _controlPort?.send({
      'type': 'url',
      'url': url,
      'token': MainApp.llmServiceToken.valueOrNull,
    });
  }

  void pause() {
    _controlPort?.send({'type': 'pause'});
  }

  void resume() {
    _controlPort?.send({'type': 'resume'});
  }

  /// Send the unwrapped DEK to the worker so it can decrypt collection tokens
  /// when embedding Google Drive files. A null DEK (vault still locked) is not
  /// sent — the worker keeps failing loudly on secret access until it arrives.
  void _sendVaultDek() {
    final dek = VaultManager.instance.dek;
    if (dek == null) {
      // Locked. Tell the worker explicitly — it cannot observe the lock
      // itself, and left alone it would keep decrypting with a stale DEK.
      _controlPort?.send({'type': 'vaultLocked'});
      return;
    }
    _controlPort?.send({'type': 'vaultDek', 'dek': dek});
  }

  static Future<void> _isolateEntry(Map<String, dynamic> cfg) async {
    // Initialize platform channel for background isolate
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      cfg['token'] as RootIsolateToken,
    );

    final String storagePath = cfg['storagePath'];
    final String dbName = cfg['dbName'];
    final AppLogger logger = AppLogger(cfg['loggerPort'] as SendPort?);
    final SendPort replyTo = cfg['replyTo'] as SendPort;

    // Create a control port to receive commands from the main isolate
    final controlPort = ReceivePort();
    replyTo.send(controlPort.sendPort);

    String? serviceUrl;
    String? serviceToken;
    bool isPaused = false;

    controlPort.listen((message) {
      if (message is Map) {
        if (message['type'] == 'url') {
          serviceUrl = message['url'];
          serviceToken = message['token'];
          logger.d("Python service URL updated: $serviceUrl");
        } else if (message['type'] == 'vaultDek') {
          // Install the credential vault so _processGDriveFile can decrypt the
          // collection's tokens (AUDIT M2 phase 4).
          CredentialCodec.installIsolateVault(message['dek'] as Uint8List?);
          logger.d("Credential vault DEK installed in embedding isolate");
        } else if (message['type'] == 'vaultLocked') {
          CredentialCodec.clearIsolateVault();
          logger.d("Credential vault DEK cleared in embedding isolate");
        } else if (message['type'] == 'pause') {
          isPaused = true;
          logger.d("EmbeddingIsolate paused during active sync");
        } else if (message['type'] == 'resume') {
          isPaused = false;
          logger.d("EmbeddingIsolate resumed after sync completion");
        }
      }
    });

    logger.i("EmbeddingIsolate starting loop");

    final db = await AppDatabase.create(null, storagePath, dbName);
    final repo = DatabaseRepository(db);

    // Initial delay to let everything settle
    await Future.delayed(const Duration(seconds: 5));

    // A full batch means there's likely more backlog waiting, so the
    // heartbeat sleep below stays short; a partial batch means the queue
    // just got drained, so it's fine to back off.
    const kBatchSize = 10;
    var lastBatchLength = 0;

    while (true) {
      try {
        if (isPaused) {
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }

        if (serviceUrl == null) {
          logger.d("Waiting for Python service URL...");
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }

        // Skip the batch entirely (no point reading/resizing/base64-encoding
        // files) while the embedding model is still downloading — the server
        // rejects these requests until it's ready anyway.
        if (!await _isEmbeddingModelReady(serviceUrl!, serviceToken, logger)) {
          logger.d("Embedding model not downloaded yet. Sleeping...");
          await Future.delayed(const Duration(seconds: 30));
          continue;
        }

        // Description vectors first, and deliberately so. They are text, so a
        // batch costs a couple of seconds against minutes for the same number
        // of images — and the description vector is the stronger signal for a
        // text query, beating the image vector on 44 of 45 photos measured.
        // After a pipeline change this puts search back on its feet in minutes
        // rather than after the whole image pass has finished.
        final staleDescriptions = await repo
            .getFilesWithStaleDescriptionEmbeddings(limit: kBatchSize);
        if (staleDescriptions.isNotEmpty) {
          logger.i(
            'Re-embedding ${staleDescriptions.length} descriptions written by '
            'an older pipeline',
          );
          for (final row in staleDescriptions) {
            if (isPaused) break;
            final embedding = await _generateTextEmbedding(
              row.description,
              serviceUrl!,
              serviceToken,
              logger,
            );
            if (embedding == null) {
              // Leave the row stale rather than stamping it: a failure here is
              // usually the subprocess being down, and marking it current
              // would retire the work permanently.
              continue;
            }
            replyTo.send({
              'type': 'embedding',
              'table': 'files_embeddings',
              'embeddingType': 'description',
              'id': row.fileId,
              'embedding': embedding,
            });
          }
          // Straight back round: there may be thousands, and they are cheap.
          continue;
        }

        // Query for a batch of files with missing embeddings
        final files = await repo.getFilesWithMissingEmbeddings(
          limit: kBatchSize,
        );
        lastBatchLength = files.length;

        if (files.isEmpty) {
          //logger.d("No files with missing embeddings found. Sleeping...");
          await Future.delayed(const Duration(minutes: 1));
          continue;
        }

        logger.i("Processing ${files.length} files for embeddings");

        for (final file in files) {
          if (isPaused) {
            logger.d("Pause requested; abandoning remaining batch");
            break;
          }
          try {
            final start = DateTime.now();
            final rawBytes = await FileBytesLoader.load(file, repo, logger);

            // Bounded before it crosses to the model. The vision tower's cost
            // scales with pixel count, so a full-resolution photo spent well
            // over a minute here for a vector that describes the same scene as
            // one built from 1024px. It also converts RAW and HEIC, which the
            // embedding endpoint can decode but only slowly, from files that
            // routinely run 30-100MB.
            final prepared =
                rawBytes == null
                    ? null
                    : await VisionImage.prepare(
                      rawBytes,
                      file.name,
                      serviceUrl: serviceUrl!,
                      serviceToken: serviceToken,
                      logger: logger,
                    );

            // `prepared.fileName`, not `file.name`. The aiserver chooses its
            // decoder from the extension, so a converted .nef still called
            // .nef sends JPEG bytes to rawpy and loses that photo its
            // embedding.
            final embedding =
                prepared == null
                    ? null
                    : await _generateEmbedding(
                      prepared.bytes,
                      prepared.fileName,
                      serviceUrl!,
                      serviceToken,
                      logger,
                    );
            final duration = DateTime.now().difference(start);
            logger.d("Processed file ${file.path} in $duration");

            // Hand the result back to the main isolate to write — resqlite
            // serializes writes through a single connection internally, so
            // writing here (a second, independent connection to the same
            // file) only added SQLITE_BUSY contention.
            //
            // Only relayed when generation actually succeeded: writing a
            // placeholder empty embedding for a null result would persist a
            // non-NULL BLOB, and getFilesWithMissingEmbeddings only ever
            // re-selects rows where the embedding IS NULL — a failure (a
            // missing file, a token refresh error, an aiserver outage)
            // would then be permanently excluded from retry instead of
            // picked up again next pass.
            if (embedding != null) {
              replyTo.send({
                'type': 'embedding',
                'table': 'files_embeddings',
                'id': file.id,
                'embedding': embedding,
              });
              logger.d("Sent embedding for file: ${file.path}");
            } else if (rawBytes == null) {
              // Could not read the file at all — an unmounted volume, a cloud
              // token needing refresh, a network that isn't there. This says
              // nothing about whether the image can be embedded, so it must
              // not spend an attempt: five passes during an outage would
              // retire the photo permanently, and it would stay retired once
              // the outage ended. Retried, unbudgeted, forever.
              logger.w("Could not read file, will retry: ${file.path}");
            } else {
              // Read fine and still produced nothing: the bytes themselves are
              // the problem (truncated JPEG, unsupported encoding). That is
              // what the attempt budget is for — see maxEmbeddingAttempts.
              logger.w("Skipped unprocessable file: ${file.path}");
              replyTo.send({'type': 'embeddingFailed', 'id': file.id});
            }
            // Batch complete
          } catch (e) {
            logger.e("Error processing file ${file.path}: $e");
          }
        }
      } catch (e, stack) {
        logger.e(
          "Error in EmbeddingIsolate loop: $e",
          error: e,
          stackTrace: stack,
        );
        await Future.delayed(const Duration(seconds: 30));
      }

      // Heartbeat sleep — short when the last batch was full (more backlog
      // likely waiting), otherwise the usual pace.
      await Future.delayed(
        lastBatchLength >= kBatchSize
            ? const Duration(seconds: 1)
            : const Duration(seconds: 10),
      );
    }
  }

  /// Local-disk-only check via the aiserver — never triggers a download,
  /// just reports whether the embedding model snapshot is already present.
  static Future<bool> _isEmbeddingModelReady(
    String serviceUrl,
    String? serviceToken,
    AppLogger logger,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$serviceUrl/util/model-status'),
            headers: {
              'Content-Type': 'application/json',
              ...aiServerAuthHeaders(serviceToken),
            },
            body: jsonEncode({
              'model_name': 'Qwen/Qwen3-VL-Embedding-2B',
              'filename': null,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['exists'] == true;
    } catch (e) {
      logger.d("Could not check embedding model status: $e");
      return false;
    }
  }

  /// Embeds plain text — used to refresh a description vector without
  /// touching the description itself.
  static Future<List<double>?> _generateTextEmbedding(
    String text,
    String serviceUrl,
    String? serviceToken,
    AppLogger logger,
  ) async {
    try {
      final response = await http.post(
        Uri.parse("$serviceUrl/util/embedding"),
        headers: {
          'Content-Type': 'application/json',
          ...aiServerAuthHeaders(serviceToken),
        },
        body: jsonEncode({
          'model_name': EmbeddingModel.modelName,
          'text': text,
        }),
      );
      if (response.statusCode != 200) {
        logger.e(
          "Python service error: ${response.statusCode} ${response.body}",
        );
        return null;
      }
      final data = jsonDecode(response.body);
      return (data['embedding'] as List<dynamic>).cast<double>();
    } catch (e) {
      logger.e("Error calling Python embedding service: $e");
      return null;
    }
  }

  static Future<List<double>?> _generateEmbedding(
    List<int> bytes,
    String filename,
    String serviceUrl,
    String? serviceToken,
    AppLogger logger,
  ) async {
    final base64Image = base64Encode(bytes);

    try {
      final response = await http.post(
        Uri.parse("$serviceUrl/util/embedding"),
        headers: {
          'Content-Type': 'application/json',
          ...aiServerAuthHeaders(serviceToken),
        },
        body: jsonEncode({
          'model_name': 'Qwen/Qwen3-VL-Embedding-2B',
          'filename': filename,
          'image_base64': base64Image,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> embData = data['embedding'];
        return embData.cast<double>();
      } else {
        logger.e(
          "Python service error: ${response.statusCode} ${response.body}",
        );
        return null;
      }
    } catch (e) {
      logger.e("Error calling Python embedding service: $e");
      return null;
    }
  }

  Future<void> stop() async {
    if (_vaultListener != null) {
      VaultManager.instance.unlocked.removeListener(_vaultListener!);
      _vaultListener = null;
    }
    // Killing the isolate only stops it from sending more dbWrite messages —
    // it doesn't touch writes already queued here. Wait for those to land
    // (bounded, so a stuck write can't hang shutdown) before closing the
    // port they'd reply on.
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    await _writeQueue.whenIdle.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    _receivePort?.close();
  }
}
