import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/services/utilities/file_bytes_loader.dart';
import 'package:mydatastudio/repositories/aichat_model_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/credential_codec.dart';
import 'package:mydatastudio/services/file_description_message_handler.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';
import 'package:mydatastudio/services/vault_manager.dart';

/// Matches `DEFAULT_MODEL_ALIAS` in aiserver/src/aichat/config.py — omitting
/// `model` from the chat completion request already gets this, but the
/// model-status readiness check needs the alias to look up its hf_repo/file.
const _kDefaultChatModelAlias = 'gemma4:12b';

const _kDescriptionPrompt =
    'Look at this image and respond with JSON only, matching the given '
    'schema. Write a short 1-2 sentence description of what the image '
    'shows. List common tags that describe and help group the image (its '
    'subject, setting, or mood — e.g. "beach", "sunset", "family", "food"). '
    'List the name of any well-known landmark visible in the image (e.g. '
    '"Eiffel Tower"), or leave the landmarks array empty if none are '
    'visible.';

const _kDescriptionSchema = {
  'type': 'object',
  'properties': {
    'description': {'type': 'string'},
    'tags': {
      'type': 'array',
      'items': {'type': 'string'},
    },
    'landmarks': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
  'required': ['description', 'tags', 'landmarks'],
};

/// Generates an AI description, tags, and landmarks for images with no
/// `description` yet, via the default (Gemma) vision-capable chat model —
/// mirrors [EmbeddingIsolate]'s isolate/control-port/write-relay shape, but
/// batches 10 files at a time and paces itself on a 1s/1min rhythm instead
/// of the embedding isolate's 10s/1min one (see `_isolateEntry`).
class FileDescriptionIsolate {
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

    _receivePort = ReceivePort("FileDescriptionIsolate");

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
      debugName: 'FileDescriptionIsolate',
    );

    _receivePort?.listen((data) {
      if (data is SendPort) {
        _controlPort = data;
        if (MainApp.llmServiceUrl.hasValue &&
            MainApp.llmServiceUrl.valueOrNull != null) {
          updateUrl(MainApp.llmServiceUrl.valueOrNull!);
        }
        // See embedding_isolate.dart — the DEK is needed to decrypt GDrive
        // collection tokens when the source image lives on Google Drive.
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
              logger.i('[FileDescriptionIsolate] $msg');
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
                '[FileDescriptionIsolate] $msg',
                error: data['error'],
                stackTrace: st,
              );
              break;
            case 'warning':
              logger.w('[FileDescriptionIsolate] $msg');
              break;
            case 'debug':
              logger.d('[FileDescriptionIsolate] $msg');
              break;
          }
        } else if (type == 'fileDescription') {
          // Queued rather than fired-and-forgotten — see embedding_isolate.dart.
          _writeQueue.add(() async {
            final repo = DatabaseManager.instance.repository;
            if (repo == null) {
              logger.w(
                '[FileDescriptionIsolate] dropped description for '
                'id=${data['id']}: no main database connection',
              );
              return;
            }
            await handleFileDescriptionMessage(repo, data, logger);
          });
        }
      }
    });

    MainApp.llmServiceUrl.listen((url) {
      if (url != null) {
        updateUrl(url);
      }
    });
  }

  void updateUrl(String url) {
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
    final AppLogger logger = AppLogger(cfg['loggerPort'] as SendPort?);
    final SendPort replyTo = cfg['replyTo'] as SendPort;

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
          CredentialCodec.installIsolateVault(message['dek'] as Uint8List?);
          logger.d("Credential vault DEK installed in description isolate");
        } else if (message['type'] == 'vaultLocked') {
          CredentialCodec.clearIsolateVault();
          logger.d("Credential vault DEK cleared in description isolate");
        } else if (message['type'] == 'pause') {
          isPaused = true;
          logger.d("FileDescriptionIsolate paused during active sync");
        } else if (message['type'] == 'resume') {
          isPaused = false;
          logger.d("FileDescriptionIsolate resumed after sync completion");
        }
      }
    });

    logger.i("FileDescriptionIsolate starting loop");

    final db = await AppDatabase.create(null, storagePath, dbName);
    final repo = DatabaseRepository(db);
    final modelRepo = AichatModelRepository(db);

    // Initial delay to let everything settle, matching EmbeddingIsolate.
    await Future.delayed(const Duration(seconds: 5));

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

        if (!await _isChatModelReady(
          modelRepo,
          serviceUrl!,
          serviceToken,
          logger,
        )) {
          logger.d("Chat model not downloaded yet. Sleeping...");
          await Future.delayed(const Duration(seconds: 30));
          continue;
        }

        final files = await repo.getFilesWithMissingDescriptions(limit: 10);

        if (files.isEmpty) {
          await Future.delayed(const Duration(minutes: 1));
          continue;
        }

        logger.i("Processing ${files.length} files for descriptions");

        for (final file in files) {
          if (isPaused) {
            logger.d("Pause requested; abandoning remaining batch");
            break;
          }
          try {
            final bytes = await FileBytesLoader.load(file, repo, logger);
            if (bytes == null) {
              logger.w("Skipped unprocessable file: ${file.path}");
              continue;
            }

            final analysis = await _describeImage(
              bytes,
              serviceUrl!,
              serviceToken,
              logger,
            );
            if (analysis == null) {
              logger.w("Skipped file with no usable analysis: ${file.path}");
              continue;
            }

            final embedding = await _embedText(
              analysis.description,
              serviceUrl!,
              serviceToken,
              logger,
            );
            if (embedding == null) {
              logger.w(
                "Skipped file with no description embedding: ${file.path}",
              );
              continue;
            }

            // Hand the result back to the main isolate to write — see
            // embedding_isolate.dart for why writes are relayed rather than
            // written directly from this connection.
            replyTo.send({
              'type': 'fileDescription',
              'id': file.id,
              'description': analysis.description,
              'tags': analysis.tags,
              'landmarks': analysis.landmarks,
              'embedding': embedding,
            });
            logger.d("Sent description for file: ${file.path}");
          } catch (e) {
            logger.e("Error processing file ${file.path}: $e");
          }
        }
      } catch (e, stack) {
        logger.e(
          "Error in FileDescriptionIsolate loop: $e",
          error: e,
          stackTrace: stack,
        );
        await Future.delayed(const Duration(seconds: 30));
      }

      // Brief pause before pulling the next batch of 10.
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  /// Local-disk-only check via the aiserver — mirrors
  /// `EmbeddingIsolate._isEmbeddingModelReady`, but for the default chat
  /// model rather than the embedding model.
  static Future<bool> _isChatModelReady(
    AichatModelRepository modelRepo,
    String serviceUrl,
    String? serviceToken,
    AppLogger logger,
  ) async {
    try {
      final model = await modelRepo.getByAlias(_kDefaultChatModelAlias);
      if (model == null || model.hfRepo == null || model.file == null) {
        logger.d(
          "Default chat model '$_kDefaultChatModelAlias' not configured yet.",
        );
        return false;
      }
      final response = await http
          .post(
            Uri.parse('$serviceUrl/util/model-status'),
            headers: {
              'Content-Type': 'application/json',
              ...aiServerAuthHeaders(serviceToken),
            },
            body: jsonEncode({
              'model_name': model.hfRepo,
              'filename': model.file,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['exists'] == true;
    } catch (e) {
      logger.d("Could not check chat model status: $e");
      return false;
    }
  }

  static Future<
    ({String description, List<String> tags, List<String> landmarks})?
  >
  _describeImage(
    List<int> bytes,
    String serviceUrl,
    String? serviceToken,
    AppLogger logger,
  ) async {
    final base64Image = base64Encode(bytes);

    try {
      final response = await http.post(
        Uri.parse('$serviceUrl/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          ...aiServerAuthHeaders(serviceToken),
        },
        body: jsonEncode({
          // No 'model': the server defaults to the vision-capable Gemma
          // model configured as DEFAULT_MODEL_ALIAS.
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpeg;base64,$base64Image'},
                },
                {'type': 'text', 'text': _kDescriptionPrompt},
              ],
            },
          ],
          'stream': false,
          'response_format': {
            'type': 'json_object',
            'schema': _kDescriptionSchema,
          },
        }),
      );

      if (response.statusCode != 200) {
        logger.e(
          "Python service error: ${response.statusCode} ${response.body}",
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        logger.w("Chat completion returned no choices");
        return null;
      }
      final message = (choices.first as Map<String, dynamic>)['message'];
      final content = message is Map ? message['content'] as String? : null;
      if (content == null || content.isEmpty) {
        logger.w("Chat completion returned no content");
        return null;
      }

      final parsed =
          jsonDecode(stripJsonFence(content)) as Map<String, dynamic>;
      final description = (parsed['description'] as String?)?.trim() ?? '';
      if (description.isEmpty) {
        logger.w("Chat completion returned an empty description");
        return null;
      }
      final tags =
          ((parsed['tags'] as List?) ?? const [])
              .map((t) => t.toString())
              .where((t) => t.isNotEmpty)
              .toList();
      final landmarks =
          ((parsed['landmarks'] as List?) ?? const [])
              .map((t) => t.toString())
              .where((t) => t.isNotEmpty)
              .toList();

      return (description: description, tags: tags, landmarks: landmarks);
    } catch (e) {
      logger.e("Error calling Python chat completion service: $e");
      return null;
    }
  }

  /// Strips a ```json ... ``` (or bare ``` ... ```) markdown fence around
  /// [content] if present.
  ///
  /// `response_format`'s grammar constraint is supposed to make this
  /// unnecessary, but llama.cpp's grammar sampling isn't reliably applied
  /// for MTMD (vision) chat handlers across all versions — the model can
  /// still fall back to its default "wrap JSON in a code block" habit.
  /// Stripping here is cheap insurance against that, independent of whether
  /// the underlying grammar bug ever gets fixed upstream.
  static String stripJsonFence(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('```')) return trimmed;

    final withoutOpenFence = trimmed.replaceFirst(
      RegExp(r'^```[a-zA-Z]*\s*\n?'),
      '',
    );
    final closingFenceIndex = withoutOpenFence.lastIndexOf('```');
    if (closingFenceIndex == -1) return withoutOpenFence.trim();
    return withoutOpenFence.substring(0, closingFenceIndex).trim();
  }

  /// Embeds [text] (the generated description) with the same multimodal
  /// embedding model/endpoint used for image embeddings, so the resulting
  /// vector is directly comparable to `type='file'` rows.
  static Future<List<double>?> _embedText(
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
          'model_name': 'Qwen/Qwen3-VL-Embedding-2B',
          'text': text,
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
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    await _writeQueue.whenIdle.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    _receivePort?.close();
  }
}
