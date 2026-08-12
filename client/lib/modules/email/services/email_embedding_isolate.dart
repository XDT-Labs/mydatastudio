import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/searchable_body.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/embedding_message_handler.dart';
import 'package:mydatastudio/services/sequential_write_queue.dart';

class EmailEmbeddingIsolate {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _controlPort;
  StreamSubscription<String?>? _urlSubscription;
  final SequentialWriteQueue _writeQueue = SequentialWriteQueue();

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
        } else if (type == 'embedding') {
          // Queued rather than fired-and-forgotten — see embedding_isolate.dart.
          _writeQueue.add(() async {
            final repo = DatabaseManager.instance.repository;
            if (repo == null) {
              logger.w(
                '[EmailEmbeddingIsolate] dropped embedding for id=${data['id']}: '
                'no main database connection',
              );
              return;
            }
            await handleEmbeddingMessage(repo, data, logger);
          });
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

  /// Body characters per chunk, and how much of the previous chunk each one
  /// repeats.
  ///
  /// Both measured — see §16 of the search plan. The overlap is not padding:
  /// it is what guarantees a query-length phrase is never split across two
  /// chunks and so matchable by neither. Any span shorter than [chunkOverlap]
  /// sits intact inside at least one chunk, because consecutive chunks advance
  /// by `chunkSize - chunkOverlap` and cover `chunkSize`.
  static const chunkSize = 2000;
  static const chunkOverlap = 400;

  /// The strings to embed for [email] — one per chunk of its body, each
  /// carrying the full headers.
  ///
  /// Returns a single element for 84% of a real archive (§16a: half of all
  /// bodies are under 566 characters), and that element is byte-identical to
  /// what the single-vector pipeline produced. Only long mail changes shape.
  ///
  /// Headers repeat on **every** chunk rather than only the first. That is what
  /// the benchmark measured, and it is what keeps a chunk lifted from the
  /// middle of a quoted thread attributable to the message it belongs to —
  /// without them, chunk 7 of a reply chain is anonymous text that matches
  /// `from:`-flavoured intent no better than a stranger's mail.
  static List<String> formatEmailForEmbedding(Email email) {
    final toList = email.to.join(', ');
    final ccList = (email.cc ?? []).join(', ');

    // The same text keyword search indexes — markup stripped, not raw HTML.
    //
    // This path used to fall straight back to `htmlBody`, which chunking turns
    // from a bad vector into a bad *corpus*: measured on this archive, the 380
    // HTML-only messages chunk to 8,825 pieces raw against 587 stripped. The
    // extra ~8,200 are `<td style=...>`, CSS and the occasional base64 data
    // URI — each one a separately retrievable unit competing with real text,
    // and each one an embedding call. The single largest body in the corpus
    // (243,841 chars, §16a) is one of these; stripped, the largest is 21,387.
    //
    // Sharing `searchableBodyText` with the FTS index is the point rather than
    // a convenience: two indexes that disagree about what a message *says*
    // produce results that cannot be reconciled by anything downstream.
    final stripped = searchableBodyText(email);
    // Snippet stays as a last resort — 45 messages here carry one and no body
    // of either kind, and they would otherwise embed headers alone.
    final body = stripped.isNotEmpty ? stripped : (email.snippet ?? '');

    final headers =
        'from: ${email.from}\n'
        'to: [$toList]\n'
        'cc: [$ccList]\n'
        'subject: ${email.subject ?? ""}\n\n';

    return [for (final chunk in chunkBody(body)) '$headers$chunk'];
  }

  /// Splits [body] into overlapping windows, or returns it whole when it fits.
  ///
  /// Deliberately cuts on character count rather than on sentence or paragraph
  /// boundaries. Quoted mail has no reliable structure to cut on — the same
  /// thread arrives with `>` markers, with `On ... wrote:` preambles, with
  /// neither, and HTML-derived text often has no paragraph breaks left at all —
  /// so boundary detection would work on the mail that needed it least. The
  /// overlap makes the arbitrary cut harmless, which is cheaper than being
  /// clever about where to place it.
  ///
  /// An empty body still yields one (empty) chunk, so every email gets a
  /// vector built from its headers alone rather than no vector at all.
  @visibleForTesting
  static List<String> chunkBody(String body) {
    if (body.length <= chunkSize) return [body];

    final step = chunkSize - chunkOverlap;
    final chunks = <String>[];
    for (var start = 0; start < body.length; start += step) {
      final end = math.min(start + chunkSize, body.length);
      chunks.add(body.substring(start, end));
      if (end == body.length) break;
    }
    return chunks;
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

    // A full batch means there's likely more backlog waiting, so the
    // heartbeat sleep below stays short; a partial batch means the queue
    // just got drained, so it's fine to back off.
    const kBatchSize = 100;
    var lastBatchLength = 0;

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

        final emails = await repo.getEmailsWithMissingEmbeddings(
          limit: kBatchSize,
        );
        lastBatchLength = emails.length;

        if (emails.isEmpty) {
          await Future.delayed(const Duration(minutes: 1));
          continue;
        }

        logger.i("Processing ${emails.length} emails for embeddings");

        for (final email in emails) {
          if (isPaused) {
            logger.d("Pause requested; abandoning remaining batch");
            break;
          }
          try {
            final chunks = formatEmailForEmbedding(email);
            final embeddings = <List<double>>[];
            for (final chunk in chunks) {
              final embedding = await _generateEmbedding(
                chunk,
                serviceUrl!,
                serviceToken,
                logger,
              );
              // All or nothing. A half-embedded email written now would carry
              // a model_version matching the current pipeline, which is
              // exactly what getEmailsWithMissingEmbeddings reads as "done" —
              // so the missing chunks would never be retried and that part of
              // the message would be permanently unsearchable.
              if (embedding == null) break;
              embeddings.add(embedding);
            }

            // Hand the result back to the main isolate to write — resqlite
            // serializes writes through a single connection internally, so
            // writing here (a second, independent connection to the same
            // file) only added SQLITE_BUSY contention.
            //
            // Sent as one message per email rather than one per chunk so the
            // write can replace the email's chunks atomically. Re-embedding a
            // shortened email otherwise leaves its surplus high-index chunks
            // behind, still holding the old text.
            if (embeddings.length == chunks.length) {
              replyTo.send({
                'type': 'embedding',
                'table': 'emails_embeddings',
                'id': email.id,
                'embeddings': embeddings,
              });
            } else {
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

      // Short when the last batch was full (more backlog likely waiting),
      // otherwise the usual pace.
      await Future.delayed(
        lastBatchLength >= kBatchSize
            ? const Duration(seconds: 1)
            : const Duration(seconds: 10),
      );
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

  Future<void> stop() async {
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
    // Held so it can be cancelled: unstored, every start/stop cycle left a
    // live listener pushing url updates at a dead _controlPort.
    _urlSubscription?.cancel();
    _urlSubscription = null;
    _controlPort = null;
  }
}
