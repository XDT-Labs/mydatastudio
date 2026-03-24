// dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:flutter/foundation.dart';
import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/main.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  final AppLogger logger = AppLogger(null);

  PythonManager._();

  /// Create manager for `supportDir/flet/app`.
  static Future<PythonManager> forAppSupport() async {
    final mgr = PythonManager._();
    return mgr;
  }

  Stream<String> get stdoutLines => _stdoutController.stream;
  Stream<String> get stderrLines => _stderrController.stream;

  bool get isRunning => _pythonProc != null;

  Future<void> startAiChatService() async {
    // Use a completer to ensure the aichat assets are available before proceeding.
    Completer<void> completer = Completer<void>();

    // Ensure bundled aichat assets are available in Application Support before proceeding.
    logger.d('[python] Ensuring aichat assets are available');
    await ensureAichatUnzipped().then((_) => completer.complete());

    var supportPath = (await getApplicationSupportDirectory()).path;
    if (Platform.isMacOS && AppConstants.realmName.endsWith('.dev')) {
      if (!supportPath.endsWith(AppConstants.realmName)) {
        final parent = Directory(supportPath).parent.path;
        supportPath = p.join(parent, AppConstants.realmName);
      }
    }
    _pythonDir = p.join(supportPath, "aichat");

    // Check for existing PID file and kill previous process if it exists
    final pidFile = File(p.join(_pythonDir!, 'aichat.pid'));
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

    String executableName = 'aichat';
    if (Platform.isWindows) {
      executableName = 'aichat.exe';
    }

    final executablePath = p.join(_pythonDir!, executableName);
    logger.d('[python] Executable path: $executablePath');

    String command = executablePath;
    List<String> commandArgs = [];

    if (!File(executablePath).existsSync()) {
      final msg = 'Python executable not found at $executablePath';
      _stderrController.add(msg);
      logger.e('[python] $msg');
      return;
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
        },
      );

      try {
        pidFile.writeAsStringSync('${_pythonProc!.pid}');
        logger.d('[python] Wrote PID ${_pythonProc!.pid} to ${pidFile.path}');
      } catch (e) {
        logger.d('[python] Failed to write PID file: $e');
      }

      logger.d('[python] Service process started with PID: ${_pythonProc!.pid}');

      await _pipeOutput(_pythonProc!);

      //Start default session
      MainApp.llmServiceUrl.listen((llmServiceUrl) async {
        if (llmServiceUrl != null) {
          final session = await http.post(
            Uri.parse("$llmServiceUrl/start-session"),
            headers: <String, String>{
              'Content-Type': 'application/json; charset=UTF-8',
            },
            body: jsonEncode(<String, dynamic>{
              "model_name": "bartowski/gemma-3-4b-it-GGUF",
              "filename": "gemma-3-4b-it-Q4_K_M.gguf",
            }),
          );
          logger.d(
            'Started default session: ${session.statusCode} ${session.body}',
          );
        }
      });

      stdoutLines.listen((line) {
        logger.i('[python] $line');
        print('[python] $line'); // Ensure standard Flutter debug console output
        // If it's a downloading/loading message, blast it to the UI status bar!
        if (line.contains('[LOADER]')) {
          logger.s(line.replaceAll('[LOADER]', '').trim());
        }
      });

      final urlRegex = RegExp(r'(http?:\/\/[^\s]+)');
      stderrLines.listen((line) {
        logger.i('[python] $line');
        print('[python] $line');
        if (line.contains('[LOADER]')) {
          logger.s(line.replaceAll('[LOADER]', '').trim());
        }
        final match = urlRegex.firstMatch(line);
        if (match != null) {
          final url = match.group(1);
          if (url != null) {
            logger.i('[python] AI Chat service is running at: $url');
            print('[python] AI Chat service is running at: $url');
            // Store this URL in a variable for later use.
            MainApp.llmServiceUrl.add(url);
            isLLMServiceRunning.value = true;
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        }
      });
    } catch (e) {
      final msg = 'Failed to start AI Chat service: $e';
      _stderrController.add(msg);
      logger.e('[python] $msg');
      completer.completeError(e);
    }

    return completer.future;
  }

  Future<void> stopAiChatService() async {
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
        final pidFile = File(p.join(_pythonDir!, 'aichat.pid'));
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

  /// Ensure the bundled aichat zip is unzipped into Application Support/aichat.
  /// If the destination directory already exists, this is a no-op.
  Future<void> ensureAichatUnzipped() async {
    try {
      var supportPath = (await getApplicationSupportDirectory()).path;
      if (Platform.isMacOS && AppConstants.realmName.endsWith('.dev')) {
        if (!supportPath.endsWith(AppConstants.realmName)) {
          final parent = Directory(supportPath).parent.path;
          supportPath = p.join(parent, AppConstants.realmName);
        }
      }
      final destDir = Directory(p.join(supportPath, 'aichat'));

      if (destDir.existsSync()) {
        _stdoutController.add(
          'aichat directory already exists at ${destDir.path}; skipping unzip.',
        );
        return;
      }

      String zipName = 'aichat.zip';
      if (Platform.isMacOS) {
        zipName = 'aichat-macos.zip';
      } else if (Platform.isWindows) {
        zipName = 'aichat-windows.zip';
      } else if (Platform.isLinux) {
        zipName = 'aichat-linux.zip';
      }

      // Candidate locations for the zip file in common run contexts
      final candidates =
          <String>[
            // when running from the project root
            p.join(Directory.current.path, 'app', zipName),
            // fallback to generic name
            p.join(Directory.current.path, 'app', 'aichat.zip'),
            // when running from a built executable next to an `app` folder
            p.join(p.dirname(Platform.resolvedExecutable), 'app', zipName),
            p.join(p.dirname(Platform.resolvedExecutable), 'app', 'aichat.zip'),
            // inside a macOS .app bundle Resources folder
            p.join(
              p.dirname(Platform.resolvedExecutable),
              '..',
              'Resources',
              'app',
              zipName,
            ),
            p.join(
              p.dirname(Platform.resolvedExecutable),
              '..',
              'Resources',
              'app',
              'aichat.zip',
            ),
          ].map((s) => p.normalize(s)).toList();

      //logger.d('[python] Candidates: ${candidates.join(', ')}');

      String? zipPath;
      for (final c in candidates) {
        if (File(c).existsSync()) {
          zipPath = c;
          break;
        }
      }

      if (zipPath == null) {
        final msg = 'aichat zip not found. Searched: ${candidates.join(', ')}';
        _stderrController.add(msg);
        logger.e('[python] $msg');
        return;
      }

      final tempDir = Directory(p.join(supportPath, 'aichat_temp'));
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
      tempDir.createSync(recursive: true);

      _stdoutController.add('Unzipping `$zipPath` -> `${tempDir.path}`');

      if (Platform.isWindows) {
        // On Windows, use PowerShell to expand the archive
        final result = await Process.run('powershell', [
          '-command',
          'Expand-Archive -Path "$zipPath" -DestinationPath "${tempDir.path}" -Force',
        ]);
        if (result.exitCode != 0) {
          _stderrController.add(
            'Expand-Archive failed (exit ${result.exitCode}): ${result.stderr}',
          );
          return;
        } else {
          _stdoutController.add('Unzip completed via PowerShell');
        }
      } else {
        // Use system `unzip` for macOS/Linux
        final result = await Process.run('unzip', [
          '-o',
          zipPath,
          '-d',
          tempDir.path,
        ]);
        if (result.exitCode != 0) {
          _stderrController.add(
            'unzip failed (exit ${result.exitCode}): ${result.stderr}',
          );
          return;
        } else {
          final out = (result.stdout ?? '').toString();
          _stdoutController.add('Unzip completed: ${out.trim()}');
        }
      }

      // Check contents of tempDir
      final contents =
          tempDir.listSync().where((e) {
            final name = p.basename(e.path);
            return !name.startsWith('__') && !name.startsWith('.');
          }).toList();

      if (contents.length == 1 && contents.first is Directory) {
        // It's a nested folder structure (e.g. aichat-macos/), move it to destDir
        final nestedDir = contents.first as Directory;
        _stdoutController.add(
          'Moving nested folder `${nestedDir.path}` to `${destDir.path}`',
        );
        nestedDir.renameSync(destDir.path);
        tempDir.deleteSync(recursive: true);
      } else {
        // Flat structure, rename tempDir to destDir
        _stdoutController.add('Moving `${tempDir.path}` to `${destDir.path}`');
        tempDir.renameSync(destDir.path);
      }
    } catch (e) {
      final msg = 'Exception while unzipping aichat bundle: $e';
      _stderrController.add(msg);
      logger.e('[python] $msg');
    }
  }

  Future<void> dispose() async {
    await stopAiChatService();
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
      // cleanup references when it exits
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

    // Ensure bundled aichat assets are available in Application Support before proceeding.
    await ensureAichatUnzipped();

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
