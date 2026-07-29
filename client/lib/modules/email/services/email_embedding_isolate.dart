import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

class EmailEmbeddingIsolate {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _controlPort;
  StreamSubscription<String?>? _urlSubscription;

  Future<void> start(
    String storagePath,
    String dbName,
    RootIsolateToken token,
  ) async {
    if (_isolate != null) return;

    _receivePort = ReceivePort("EmailEmbeddingIsolate");

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
      debugName: 'EmailEmbeddingIsolate',
    );

    _receivePort?.listen((data) {
      if (data is SendPort) {
        _controlPort = data;
        if (MainApp.llmServiceUrl.hasValue &&
            MainApp.llmServiceUrl.valueOrNull != null) {
          updateUrl(MainApp.llmServiceUrl.valueOrNull!);
        }
      } else if (data is Map) {
        final type = data['type'];
        final msg = data['message'];
        final logger = AppLogger(null);

        if (type == 'log') {
          final level = data['level'] as String;
          switch (level) {
            case 'info':
              logger.i('[EmailEmbeddingIsolate] $msg');
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
                '[EmailEmbeddingIsolate] $msg',
                error: data['error'],
                stackTrace: st,
              );
              break;
            case 'warning':
              logger.w('[EmailEmbeddingIsolate] $msg');
              break;
            case 'debug':
              logger.d('[EmailEmbeddingIsolate] $msg');
              break;
          }
        }
      }
    });

    _urlSubscription = MainApp.llmServiceUrl.listen((url) {
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

  static String formatEmailForEmbedding(Email email) {
    final toList = email.to.join(', ');
    final ccList = (email.cc ?? []).join(', ');
    final body = email.plainBody ?? email.snippet ?? email.htmlBody ?? '';

    return 'from: ${email.from}\n'
        'to: [$toList]\n'
        'cc: [$ccList]\n'
        'subject: ${email.subject ?? ""}\n\n'
        '$body';
  }

  static Future<void> _isolateEntry(Map<String, dynamic> cfg) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      cfg['token'] as RootIsolateToken,
    );

    final String storagePath = cfg['storagePath'];
    final String dbName = cfg['dbName'];
    final AppLogger logger = AppLogger(cfg['loggerPort'] as SendPort?);

    final controlPort = ReceivePort();
    cfg['replyTo'].send(controlPort.sendPort);

    String? serviceUrl;
    String? serviceToken;
    bool isPaused = false;

    controlPort.listen((message) {
      if (message is Map) {
        if (message['type'] == 'url') {
          serviceUrl = message['url'];
          serviceToken = message['token'];
          logger.d(
            "Python service URL updated for EmailEmbeddingIsolate: $serviceUrl",
          );
        } else if (message['type'] == 'pause') {
          isPaused = true;
          logger.d("EmailEmbeddingIsolate paused during active sync");
        } else if (message['type'] == 'resume') {
          isPaused = false;
          logger.d("EmailEmbeddingIsolate resumed after sync completion");
        }
      }
    });

    logger.i("EmailEmbeddingIsolate starting loop");

    final db = await AppDatabase.create(null, storagePath, dbName);
    final repo = DatabaseRepository(db);

    await Future.delayed(const Duration(seconds: 5));

    while (true) {
      try {
        if (isPaused) {
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }

        if (serviceUrl == null) {
          logger.d(
            "Waiting for Python service URL in EmailEmbeddingIsolate...",
          );
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }

        if (!await _isEmbeddingModelReady(serviceUrl!, serviceToken, logger)) {
          logger.d(
            "Embedding model not downloaded yet. Sleeping in EmailEmbeddingIsolate...",
          );
          await Future.delayed(const Duration(seconds: 30));
          continue;
        }

        final emails = await repo.getEmailsWithMissingEmbeddings(limit: 10);

        if (emails.isEmpty) {
          await Future.delayed(const Duration(minutes: 1));
          continue;
        }

        logger.i("Processing ${emails.length} emails for embeddings");

        for (final email in emails) {
          try {
            final formattedText = formatEmailForEmbedding(email);
            final embedding = await _generateEmbedding(
              formattedText,
              serviceUrl!,
              serviceToken,
              logger,
            );
            // logger.d("Processed email ${email.id} in $duration");

            if (embedding != null) {
              await repo.upsertEmailEmbedding(email.id, embedding);
              // logger.d("Saved embedding for email: ${email.id}");
            } else {
              await repo.upsertEmailEmbedding(email.id, []);
              logger.w("Skipped unprocessable email: ${email.id}");
            }
          } catch (e) {
            logger.e("Error processing email ${email.id}: $e");
          }
        }
      } catch (e, stack) {
        logger.e(
          "Error in EmailEmbeddingIsolate loop: $e",
          error: e,
          stackTrace: stack,
        );
        await Future.delayed(const Duration(seconds: 30));
      }

      await Future.delayed(const Duration(seconds: 10));
    }
  }

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

  static Future<List<double>?> _generateEmbedding(
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

  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    // Held so it can be cancelled: unstored, every start/stop cycle left a
    // live listener pushing url updates at a dead _controlPort.
    _urlSubscription?.cancel();
    _urlSubscription = null;
    _controlPort = null;
  }
}
