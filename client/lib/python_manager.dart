// dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:path/path.dart' as p;

class PythonManager {
  Process? _pythonProc;
  Process? _pipProc;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  final StreamController<String> _stdoutController =
      StreamController.broadcast();
  final StreamController<String> _stderrController =
      StreamController.broadcast();

  String? _pythonDir;
  static ValueNotifier<bool> isLLMServiceRunning = ValueNotifier(false);
  static ValueNotifier<String> startupProgress = ValueNotifier('Starting...');

  final AppLogger logger = AppLogger(null);
  Completer<void>? _startupCompleter;
  @visibleForTesting
  final RegExp urlRegex = RegExp(r'(http://(?:127\.0\.0\.1|localhost):\d+)');

  PythonManager._() {
    _initOutputStreams();
  }

  void _initOutputStreams() {
    stdoutLines.listen(_handleOutputLine);
    stderrLines.listen(_handleOutputLine);
  }

  void _handleOutputLine(String line) {
    logger.i('[python] $line');
    print('[python] $line'); // Ensure standard Flutter debug console output
    if (line.contains('[LOADER]')) {
      logger.s(line.replaceAll('[LOADER]', '').trim());
    }
    // Update splash screen progress
    PythonManager.startupProgress.value = line;

    final match = urlRegex.firstMatch(line);
    if (match != null) {
      final url = match.group(1);
      if (url != null) {
        logger.i('[python] AI Chat service is running at: $url');
        print('[python] AI Chat service is running at: $url');
        MainApp.llmServiceUrl.add(url);
        isLLMServiceRunning.value = true;
        if (_startupCompleter != null && !_startupCompleter!.isCompleted) {
          _startupCompleter!.complete();
        }
      }
    }
  }

  /// Create manager for `supportDir/flet/app`.
  static Future<PythonManager> forAppSupport() async {
    final mgr = PythonManager._();
    return mgr;
  }

  Stream<String> get stdoutLines => _stdoutController.stream;
  Stream<String> get stderrLines => _stderrController.stream;

  bool get isRunning => _pythonProc != null;

  Future<void> startAiServerService() async {
    const remoteUrl = String.fromEnvironment('PYTHON_SERVER_URL');
    if (remoteUrl.isNotEmpty) {
      logger.i('[python] Starting remote AI Chat service at: $remoteUrl');
      MainApp.llmServiceUrl.add(remoteUrl);
      isLLMServiceRunning.value = true;
      PythonManager.startupProgress.value = 'Connected to remote AI service';
      return Future.value();
    }

    PythonManager.startupProgress.value = 'Preparing AI service...';
    // Use a completer to ensure the aiserver assets are available before proceeding.
    Completer<void> completer = Completer<void>();
    _startupCompleter = completer;

    // Ensure bundled aiserver assets are available in Application Support before proceeding.
    logger.d('[python] Ensuring aiserver assets are available');
    try {
      await ensureAiserverUnzipped();
    } catch (e) {
      completer.completeError(e);
      return completer.future;
    }

    var supportPath = await DatabaseManager.getRealApplicationSupportPath();
    _pythonDir = p.join(supportPath, "aiserver");

    // Check for existing PID file and kill previous process if it exists
    final pidFile = File(p.join(_pythonDir!, 'aiserver.pid'));
    if (pidFile.existsSync()) {
      try {
        final oldPid = int.parse(pidFile.readAsStringSync().trim());
        logger.d('[python] Found existing PID file with PID: $oldPid');
        if (Process.killPid(oldPid, ProcessSignal.sigkill)) {
          logger.d('[python] Successfully killed old process $oldPid');
        } else {
          logger.d(
            '[python] Failed to kill old process $oldPid (might not be running)',
          );
        }
      } catch (e) {
        logger.d('[python] Error handling existing PID file: $e');
      }
    }

    logger.d('[python] Starting AI Chat service in `$_pythonDir`');

    String executableName = 'aiserver';
    if (Platform.isWindows) {
      executableName = 'aiserver.exe';
    }

    final executablePath = p.join(_pythonDir!, executableName);
    logger.d('[python] Executable path: $executablePath');

    String command = executablePath;
    List<String> commandArgs = [];

    if (!File(executablePath).existsSync()) {
      final msg = 'Python executable not found at $executablePath';
      _stderrController.add(msg);
      logger.e('[python] $msg');
      completer.completeError(Exception(msg));
      return completer.future;
    }

    // Ensure executable permission on Unix-like systems if using compiled binary
    if (!Platform.isWindows && command == executablePath) {
      await Process.run('chmod', ['+x', executablePath]);
    }

    try {
      logger.d("Starting AI Chat service...");
      _pythonProc = await Process.start(
        command,
        commandArgs,
        workingDirectory: _pythonDir,
        environment: {
          'PYTHONUNBUFFERED': '1',
          'HF_TOKEN': '', //todo pass from client
          'GOOGLE_API_KEY': '', //todo pass from client
          'MODEL_DOWNLOAD_URL':
              'https://gcs-file-downloader-10805446439.us-central1.run.app', // todo get from remote config
          'APP_SUPPORT_DIR': supportPath,
          'AICHAT_MODELS_DIR': p.join(_pythonDir!, 'models'),
          'AISERVER_LOG_LEVEL': MainApp.logLevel,
        },
      );

      try {
        pidFile.writeAsStringSync('${_pythonProc!.pid}');
        logger.d('[python] Wrote PID ${_pythonProc!.pid} to ${pidFile.path}');
      } catch (e) {
        logger.d('[python] Failed to write PID file: $e');
      }

      logger.d(
        '[python] Service process started with PID: ${_pythonProc!.pid}',
      );

      await _pipeOutput(_pythonProc!);
    } catch (e) {
      final msg = 'Failed to start AI Chat service: $e';
      _stderrController.add(msg);
      logger.e('[python] $msg');
      completer.completeError(e);
    }

    return completer.future;
  }

  Future<void> stopAiServerService() async {
    // stop python proc first
    if (_pythonProc != null) {
      try {
        _pythonProc!.kill(ProcessSignal.sigterm);
        await _pythonProc!.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      } catch (_) {}
      _pythonProc = null;
    }
    if (_pipProc != null) {
      try {
        _pipProc!.kill(ProcessSignal.sigterm);
        await _pipProc!.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        );
      } catch (_) {}
      _pipProc = null;
    }

    // Cleanup PID file
    if (_pythonDir != null) {
      try {
        final pidFile = File(p.join(_pythonDir!, 'aiserver.pid'));
        if (pidFile.existsSync()) {
          pidFile.deleteSync();
          logger.d('[python] Deleted PID file');
        }
      } catch (e) {
        logger.d('[python] Error deleting PID file: $e');
      }
    }

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
  }

  /// Ensure the bundled aiserver zip is unzipped into Application Support/aiserver.
  /// If the destination directory already exists, this is a no-op.
  Future<void> ensureAiserverUnzipped() async {
    try {
      var supportPath = await DatabaseManager.getRealApplicationSupportPath();
      final destDir = Directory(p.join(supportPath, 'aiserver'));

      if (destDir.existsSync()) {
        _stdoutController.add(
          'aiserver directory already exists at ${destDir.path}; skipping unzip.',
        );
        PythonManager.startupProgress.value = 'Starting AI service...';
        return;
      }

      String zipName = 'aiserver.zip';
      if (Platform.isMacOS) {
        zipName = 'aiserver-macos.zip';
      } else if (Platform.isWindows) {
        zipName = 'aiserver-windows.zip';
      } else if (Platform.isLinux) {
        zipName = 'aiserver-linux.zip';
      }

      // Candidate locations for the zip file in common run contexts
      final candidates =
          <String>[
            // when manually placed/copied for local testing via makefile
            p.join(supportPath, zipName),
            // when running from the project root
            p.join(Directory.current.path, 'client', 'app', zipName),
            // fallback when running from client folder directly
            p.join(Directory.current.path, 'app', zipName),
            // when running from a built executable next to an `app` folder
            p.join(p.dirname(Platform.resolvedExecutable), 'app', zipName),
            // inside a macOS .app bundle Frameworks flutter_assets folder (release build)
            p.join(
              p.dirname(Platform.resolvedExecutable),
              '..',
              'Frameworks',
              'App.framework',
              'Resources',
              'flutter_assets',
              'app',
              zipName,
            ),
            // inside a macOS .app bundle flutter_assets folder
            p.join(
              p.dirname(Platform.resolvedExecutable),
              '..',
              'Resources',
              'flutter_assets',
              'app',
              zipName,
            ),
            // inside a macOS .app bundle Resources folder
            p.join(
              p.dirname(Platform.resolvedExecutable),
              '..',
              'Resources',
              'app',
              zipName,
            ),
          ].map((s) => p.normalize(s)).toList();

      logger.d('[python] Candidate search paths: ${candidates.join(', ')}');

      String? zipPath;
      for (final c in candidates) {
        if (File(c).existsSync()) {
          zipPath = c;
          break;
        }
      }

      if (zipPath == null) {
        final msg =
            'aiserver zip not found. Searched candidates: ${candidates.join(', ')}';
        _stderrController.add(msg);
        logger.e('[python] $msg');
        throw Exception(msg);
      }

      final tempDir = Directory(p.join(supportPath, 'aiserver_temp'));
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
      tempDir.createSync(recursive: true);

      _stdoutController.add('Unzipping `$zipPath` -> `${tempDir.path}`');

      if (Platform.isWindows) {
        // On Windows, use PowerShell to expand the archive
        PythonManager.startupProgress.value =
            'Extracting AI Chat service (this may take a few minutes)...';
        final proc = await Process.start('powershell', [
          '-command',
          'Expand-Archive -Path "$zipPath" -DestinationPath "${tempDir.path}" -Force',
        ]);
        int lastUpdate = DateTime.now().millisecondsSinceEpoch;
        proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              int now = DateTime.now().millisecondsSinceEpoch;
              if (now - lastUpdate > 1000) {
                if (line.trim().isNotEmpty) {
                  PythonManager.startupProgress.value = 'Extracting... $line';
                  lastUpdate = now;
                }
              }
            });
        proc.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              _stderrController.add('Expand-Archive err: $line');
            });

        final exitCode = await proc.exitCode;
        if (exitCode != 0) {
          final msg = 'Expand-Archive failed (exit $exitCode)';
          _stderrController.add(msg);
          logger.e('[python] $msg');
          throw Exception(msg);
        } else {
          _stdoutController.add('Unzip completed via PowerShell');
        }
      } else {
        // Use system `unzip` for macOS/Linux
        PythonManager.startupProgress.value = 'Unzipping AI Chat service...';
        final proc = await Process.start('unzip', [
          '-o',
          zipPath,
          '-d',
          tempDir.path,
        ]);

        int lastUpdate = DateTime.now().millisecondsSinceEpoch;
        proc.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line.contains('inflating:')) {
                int now = DateTime.now().millisecondsSinceEpoch;
                if (now - lastUpdate > 100) {
                  String file = line.split('inflating:')[1].trim();
                  if (file.length > 50) {
                    file = '...${file.substring(file.length - 47)}';
                  }
                  PythonManager.startupProgress.value = 'Unzipping: $file';
                  lastUpdate = now;
                }
              }
            });

        proc.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              _stderrController.add('unzip err: $line');
            });

        final exitCode = await proc.exitCode;
        if (exitCode != 0) {
          final msg = 'unzip failed (exit $exitCode)';
          _stderrController.add(msg);
          logger.e('[python] $msg');
          throw Exception(msg);
        } else {
          _stdoutController.add('Unzip completed');
        }
      }

      // Check contents of tempDir
      final contents =
          tempDir.listSync().where((e) {
            final name = p.basename(e.path);
            return !name.startsWith('__') && !name.startsWith('.');
          }).toList();

      if (contents.length == 1 && contents.first is Directory) {
        // It's a nested folder structure (e.g. aiserver-macos/), move it to destDir
        PythonManager.startupProgress.value = 'Finalizing setup...';
        final nestedDir = contents.first as Directory;
        _stdoutController.add(
          'Moving nested folder `${nestedDir.path}` to `${destDir.path}`',
        );
        nestedDir.renameSync(destDir.path);
        tempDir.deleteSync(recursive: true);
      } else {
        // Flat structure, rename tempDir to destDir
        PythonManager.startupProgress.value = 'Finalizing setup...';
        _stdoutController.add('Moving `${tempDir.path}` to `${destDir.path}`');
        tempDir.renameSync(destDir.path);
      }
    } catch (e) {
      final msg = 'Exception while unzipping aiserver bundle: $e';
      _stderrController.add(msg);
      logger.e('[python] $msg');
      rethrow;
    }
  }

  Future<void> dispose() async {
    await stopAiServerService();
    await _stdoutController.close();
    await _stderrController.close();
  }

  Future<void> _pipeOutput(Process proc) async {
    _stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stdoutController.add);
    _stderrSub = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderrController.add);
    proc.exitCode.then((code) {
      _stdoutController.add('Python exited with code $code');
      if (_startupCompleter != null && !_startupCompleter!.isCompleted) {
        _startupCompleter!.completeError(
          Exception('Python server exited with code $code.'),
        );
      }
      _pythonProc = null;
    });
  }

  /**
  Future<void> diagnoseAndStartPython() async {
    final pythonDir = _pythonDir;
    if (pythonDir == null) {
      _stderrController.add('pythonDir not initialized');
      return;
    }

    // Ensure bundled aiserver assets are available in Application Support before proceeding.
    await ensureAiserverUnzipped();

    if (!Directory(pythonDir).existsSync()) {
      _stderrController.add('Directory not found: `$pythonDir`');
      return;
    }

    final venvPython = p.join(pythonDir, '.venv', 'bin', 'python3');
    final mainPy = p.join(pythonDir, 'main.py');

    if (!File(mainPy).existsSync()) {
      _stderrController.add('`main.py` not found in `$pythonDir`');
      return;
    }

    String pythonExe = 'python3'; // fallback
    if (File(venvPython).existsSync()) {
      final stat = FileStat.statSync(venvPython);
      final hasExec = (stat.mode & 0x111) != 0;
      _stdoutController.add('venv python mode: ${stat.mode.toRadixString(8)} exec? $hasExec');

      if (!hasExec) {
        try {
          final chmod = await Process.run('chmod', ['+x', venvPython]);
          if (chmod.exitCode == 0) {
            _stdoutController.add('Made `$venvPython` executable');
            if ((FileStat.statSync(venvPython).mode & 0x111) != 0) {
              pythonExe = venvPython;
            }
          } else {
            _stderrController.add('chmod failed: ${chmod.stderr}');
          }
        } catch (e) {
          _stderrController.add('chmod exception: $e');
        }
        if (pythonExe != venvPython) {
          _stdoutController.add('Falling back to system `python3`');
        }
      } else {
        pythonExe = venvPython;
      }
    } else {
      _stdoutController.add('venv python not found; using system `python3`');
    }

    final isInAppBundle = Platform.resolvedExecutable.contains('.app');
    if (isInAppBundle) {
      _stdoutController.add('App appears to be running from a `.app` bundle. Packaged/sandboxed apps may be prevented from spawning processes or accessing some paths.');
    }

    try {
      // optional: install requirements first
      _pipProc = await Process.start(
        pythonExe,
        ['-m', 'pip', 'install', '-r', 'requirements.txt'],
        workingDirectory: pythonDir,
        runInShell: false,
      );
      _pipProc!.stdout.transform(utf8.decoder).listen((d) => _stdoutController.add('PIP: $d'));
      _pipProc!.stderr.transform(utf8.decoder).listen((d) => _stderrController.add('PIP ERR: $d'));
      final pipExit = await _pipProc!.exitCode;
      if (pipExit != 0) _stderrController.add('pip install exit code $pipExit');

      // start python app
      _pythonProc = await Process.start(
        pythonExe,
        ['main.py'],
        workingDirectory: pythonDir,
        runInShell: false,
      );
      await _pipeOutput(_pythonProc!);
      _stdoutController.add('Python server process started.');
    } catch (e) {
      _stderrController.add('Failed to start python process: $e');
    }
  }
**/
}
