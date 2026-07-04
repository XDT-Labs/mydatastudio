import 'dart:isolate';

import 'dart:io';

import 'package:logger/logger.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/main.dart';

class ConcisePrinter extends LogPrinter {
  final PrettyPrinter _errorPrinter = PrettyPrinter(
    methodCount: 8,
    errorMethodCount: 8,
    lineLength: 120,
    colors: true,
    printEmojis: true,
    dateTimeFormat: DateTimeFormat.dateAndTime,
  );

  static final levelEmojis = {
    Level.trace: '🐱',
    Level.debug: '🐛',
    Level.info: '💡',
    Level.warning: '⚠️',
    Level.error: '⛔',
    Level.fatal: '👾',
  };

  @override
  List<String> log(LogEvent event) {
    if (event.level == Level.error ||
        event.level == Level.warning ||
        event.level == Level.fatal) {
      return _errorPrinter.log(event);
    }

    final String emoji = levelEmojis[event.level] ?? '';
    final String message = event.message.toString();

    // Extract call site
    String callSite = "";
    try {
      final stackTrace = StackTrace.current.toString().split('\n');
      // print('STACK TRACE: $stackTrace');
      // We need to find the first frame outside of logger/app_logger
      for (var frame in stackTrace) {
        // print('FRAME: $frame');
        if (!frame.contains('app_logger.dart') &&
            !frame.contains('package:logger')) {
          // Format of frame is usually: #N   ClassName.MethodName (package:path/to/file.dart:line:col) or (file:///path/to/file.dart:line:col)
          final match = RegExp(r'\(((?:package|file):.*)\)').firstMatch(frame);
          if (match != null) {
            callSite = match.group(1) ?? "";
            // Clean up the path to be more concise
            if (callSite.contains('package:mydatastudio/')) {
              callSite = callSite.replaceAll('package:mydatastudio/', '');
            } else if (callSite.contains('file:///')) {
              callSite = p.basename(callSite);
            }
            break;
          }
        }
      }
    } catch (e) {
      // ignore
    }

    final String timeStr = DateTime.now().toIso8601String().split('.').first;
    return ['$timeStr │ $emoji [$callSite] $message'];
  }
}

class CustomLogOutput extends LogOutput {
  final ConsoleOutput consoleOutput = ConsoleOutput();

  // Shared across every AppLogger/CustomLogOutput instance in this isolate —
  // AppLogger(...) is constructed ad-hoc throughout the app (and once per
  // relayed message in isolate loops), but they must all append to the same
  // session log file rather than each opening its own.
  static File? _logFile;
  static int _bytesWritten = 0;
  static bool _cleanedOldLogs = false;
  static const int _maxBytesPerFile = 10 * 1024 * 1024; // 10MB
  static const Duration _maxLogAge = Duration(days: 7);

  @override
  Future<void> init() async {
    await consoleOutput.init();
    await super.init();
  }

  @override
  void output(OutputEvent event) {
    consoleOutput.output(event);

    try {
      _ensureLogFile();

      if (_logFile != null) {
        // Strip ANSI color codes
        final parsedLines = event.lines
            .map((l) => l.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), ''))
            .join('\n');
        final text = '$parsedLines\n';
        _logFile!.writeAsStringSync(text, mode: FileMode.append);
        _bytesWritten += text.length;

        if (_bytesWritten >= _maxBytesPerFile) {
          _rotateLogFile(_logFile!.parent);
        }
      }
    } catch (_) {
      // Ignore file writing errors
    }
  }

  static void _ensureLogFile() {
    if (_logFile != null) return;
    // Safe to check because in isolates, this subject is empty.
    if (!MainApp.appDataDirectory.hasValue ||
        MainApp.appDataDirectory.value == null) {
      return;
    }

    final logDir = Directory(p.join(MainApp.appDataDirectory.value!, 'logs'));
    if (!logDir.existsSync()) {
      logDir.createSync(recursive: true);
    }

    if (!_cleanedOldLogs) {
      _cleanedOldLogs = true;
      _deleteOldLogs(logDir);
    }

    _rotateLogFile(logDir);
  }

  /// Opens a new session log file. Called once at startup, and again if the
  /// current file grows past [_maxBytesPerFile] during a long-running session.
  static void _rotateLogFile(Directory logDir) {
    final ts = DateTime.now()
        .toIso8601String()
        .split('.')
        .first
        .replaceAll(':', '-')
        .replaceAll('T', '_');
    _logFile = File(p.join(logDir.path, 'app_$ts.log'));
    _bytesWritten = 0;
  }

  /// Deletes app/aiserver log files older than [_maxLogAge], run once per
  /// process on first log write.
  static void _deleteOldLogs(Directory logDir) {
    final cutoff = DateTime.now().subtract(_maxLogAge);
    try {
      for (final entity in logDir.listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('app_') && !name.startsWith('aiserver_')) {
          continue;
        }
        if (entity.statSync().modified.isBefore(cutoff)) {
          entity.deleteSync();
        }
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  }

  @override
  Future<void> destroy() async {
    await consoleOutput.destroy();
    await super.destroy();
  }
}

class AppLogger extends Logger {
  SendPort? sendPort;

  AppLogger(this.sendPort, {super.filter})
    : super(printer: ConcisePrinter(), output: CustomLogOutput());

  @override
  void log(
    Level level,
    dynamic message, {
    DateTime? time,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (sendPort != null) {
      // If we are in an isolate, send a message back to the main isolate
      sendPort!.send({
        'type': 'log',
        'level': level.name,
        'message': message.toString(),
        'error': error?.toString(),
        'stackTrace': stackTrace?.toString(),
      });
    }
    super.log(level, message, time: time, error: error, stackTrace: stackTrace);
  }

  static PublishSubject<String> statusSubject = PublishSubject<String>();

  /// Sends a status message. If in an isolate, uses the sendPort.
  void s(dynamic message) {
    if (sendPort != null) {
      sendPort!.send({'type': 'status', 'message': message.toString()});
    } else {
      statusSubject.add(message.toString());
    }
  }
}
