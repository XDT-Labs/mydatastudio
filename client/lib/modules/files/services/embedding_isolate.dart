import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/oauth/google_auth_client.dart';
import 'package:mydatatools/repositories/database_repository.dart';

class EmbeddingIsolate {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _controlPort;

  Future<void> start(
    String storagePath,
    String dbName,
    SendPort writerPort,
    RootIsolateToken token,
  ) async {
    if (_isolate != null) return;

    _receivePort = ReceivePort("EmbeddingIsolate");

    Map<String, dynamic> cfg = {
      'replyTo': _receivePort!.sendPort,
      'storagePath': storagePath,
      'dbName': dbName,
      'writerPort': writerPort,
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
            MainApp.llmServiceUrl.value != null) {
          updateUrl(MainApp.llmServiceUrl.value!);
        }
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
              logger.e(
                '[EmbeddingIsolate] $msg',
                error: data['error'],
                stackTrace: data['stackTrace'],
              );
              break;
            case 'warning':
              logger.w('[EmbeddingIsolate] $msg');
              break;
            case 'debug':
              logger.d('[EmbeddingIsolate] $msg');
              break;
          }
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
    _controlPort?.send({'type': 'url', 'url': url});
  }

  static Future<void> _isolateEntry(Map<String, dynamic> cfg) async {
    // Initialize platform channel for background isolate
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      cfg['token'] as RootIsolateToken,
    );

    final SendPort writerPort = cfg['writerPort'];
    final String storagePath = cfg['storagePath'];
    final String dbName = cfg['dbName'];
    final AppLogger logger = AppLogger(cfg['loggerPort'] as SendPort?);

    // Create a control port to receive commands from the main isolate
    final controlPort = ReceivePort();
    cfg['replyTo'].send(controlPort.sendPort);

    String? serviceUrl;
    controlPort.listen((message) {
      if (message is Map && message['type'] == 'url') {
        serviceUrl = message['url'];
        logger.d("Python service URL updated: $serviceUrl");
      }
    });

    logger.i("EmbeddingIsolate starting loop");

    final db = AppDatabase(null, storagePath, dbName, false);
    final repo = DatabaseRepository(db);

    // Initial delay to let everything settle
    await Future.delayed(const Duration(seconds: 5));

    while (true) {
      try {
        if (serviceUrl == null) {
          logger.d("Waiting for Python service URL...");
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }

        // Query for 10 files with missing embeddings
        final files = await repo.getFilesWithMissingEmbeddings(limit: 10);

        if (files.isEmpty) {
          logger.d("No files with missing embeddings found. Sleeping...");
          await Future.delayed(const Duration(minutes: 1));
          continue;
        }

        logger.i("Processing ${files.length} files for embeddings");

        for (final file in files) {
          try {
            List<double>? embedding;
            final start = DateTime.now();
            if (file.path.startsWith('gdrive://')) {
              embedding = await _processGDriveFile(
                file,
                repo,
                serviceUrl!,
                logger,
              );
            } else {
              embedding = await _processLocalFile(file, serviceUrl!, logger);
            }
            final duration = DateTime.now().difference(start);
            logger.d("Processed file ${file.path} in $duration");

            print(embedding);

            if (embedding != null) {
              // Send to DbIsolateWriter
              final responsePort = ReceivePort();
              writerPort.send({
                'type': 'embedding',
                'fileId': file.id,
                'embedding': embedding,
                'replyTo': responsePort.sendPort,
              });
              await responsePort.first;
              responsePort.close();
              logger.d("Saved embedding for file: ${file.path}");
            }
            // Batch complete
          } catch (e) {
            logger.e("Error processing file ${file.path}: $e");
          }
        }

        break; // temporary while debugging
      } catch (e, stack) {
        logger.e(
          "Error in EmbeddingIsolate loop: $e",
          error: e,
          stackTrace: stack,
        );
        await Future.delayed(const Duration(seconds: 30));
      }

      // Heartbeat sleep
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  static Future<List<double>?> _processLocalFile(
    File file,
    String serviceUrl,
    AppLogger logger,
  ) async {
    final ioFile = io.File(file.path);
    if (!ioFile.existsSync()) {
      logger.w("File not found: ${file.path}");
      return null;
    }

    final bytes = await ioFile.readAsBytes();
    return await _generateEmbedding(bytes, serviceUrl, logger);
  }

  static Future<List<double>?> _processGDriveFile(
    File file,
    DatabaseRepository repo,
    String serviceUrl,
    AppLogger logger,
  ) async {
    final collection = await repo.getCollection(file.collectionId);
    if (collection == null) {
      logger.w("Collection not found for GDrive file: ${file.path}. Skipping.");
      return null;
    }

    final fileId = file.path.replaceFirst('gdrive://', '');

    // Refresh token if needed
    String? accessToken = collection.accessToken;
    final now = DateTime.now().toUtc();
    final nearExpiry =
        collection.expiration == null ||
        now.isAfter(
          collection.expiration!.subtract(const Duration(minutes: 5)),
        );

    if (nearExpiry && collection.refreshToken != null) {
      try {
        final result = await GoogleDriveAuthService.refreshTokens(
          accessToken: collection.accessToken!,
          refreshToken: collection.refreshToken!,
        );
        accessToken = result.accessToken;
        // Optionally we could update the DB here, but let's just use it for now
      } catch (e) {
        logger.e("GDrive token refresh failed: $e");
        return null;
      }
    }

    if (accessToken == null) {
      logger.w("No access token for GDrive file: ${file.path}");
      return null;
    }

    final driveApi = drive.DriveApi(
      GoogleAuthClient({'Authorization': 'Bearer $accessToken'}),
    );

    try {
      final media =
          await driveApi.files.get(
                fileId,
                downloadOptions: drive.DownloadOptions.fullMedia,
              )
              as drive.Media;
      final bytes = await http.ByteStream(media.stream).toBytes();
      return await _generateEmbedding(bytes, serviceUrl, logger);
    } catch (e) {
      logger.e("Error downloading GDrive file: $e");
      return null;
    }
  }

  static Future<List<double>?> _generateEmbedding(
    List<int> bytes,
    String serviceUrl,
    AppLogger logger,
  ) async {
    final base64Image = base64Encode(bytes);

    try {
      final response = await http.post(
        Uri.parse("$serviceUrl/embedding"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model_name': 'mradermacher/Qwen3-Embedding-8B-GGUF',
          'filename': 'Qwen3-Embedding-8B-Q4_K_M.gguf',
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

  void stop() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
  }
}
