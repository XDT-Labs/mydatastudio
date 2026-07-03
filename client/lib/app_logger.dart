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
  File? _logFile;
  bool _initialized = false;

  @override
  Future<void> init() async {
    await consoleOutput.init();
    await super.init();
  }

  @override
  void output(OutputEvent event) {
    consoleOutput.output(event);

    try {
      if (!_initialized) {
        // Safe to check because in isolates, this subject is empty.
        if (MainApp.appDataDirectory.hasValue &&
            MainApp.appDataDirectory.value != null) {
          final logDir = Directory(
            p.join(MainApp.appDataDirectory.value!, 'logs'),
          );
          if (!logDir.existsSync()) {
            logDir.createSync(recursive: true);
          }
          // Unique timestamp per startup so each run gets its own log file.
          final ts = DateTime.now()
              .toIso8601String()
              .split('.')
              .first
              .replaceAll(':', '-')
              .replaceAll('T', '_');
          _logFile = File(p.join(logDir.path, 'app_$ts.log'));
          _initialized = true;
        }
      }

      if (_logFile != null) {
        // Strip ANSI color codes
        final parsedLines = event.lines
            .map((l) => l.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), ''))
            .join('\n');
        final text = '$parsedLines\n';
        _logFile!.writeAsStringSync(text, mode: FileMode.append);
      }
    } catch (_) {
      // Ignore file writing errors
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
