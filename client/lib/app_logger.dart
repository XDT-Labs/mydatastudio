import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:rxdart/rxdart.dart';
import 'package:path/path.dart' as p;

class ConcisePrinter extends LogPrinter {
  final PrettyPrinter _errorPrinter = PrettyPrinter(
    methodCount: 8,
    errorMethodCount: 8,
    lineLength: 120,
    colors: true,
    printEmojis: true,
    dateTimeFormat: DateTimeFormat.none,
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
    if (event.level == Level.error || event.level == Level.warning || event.level == Level.fatal) {
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
        if (!frame.contains('app_logger.dart') && !frame.contains('package:logger')) {
          // Format of frame is usually: #N   ClassName.MethodName (package:path/to/file.dart:line:col) or (file:///path/to/file.dart:line:col)
          final match = RegExp(r'\(((?:package|file):.*)\)').firstMatch(frame);
          if (match != null) {
            callSite = match.group(1) ?? "";
            // Clean up the path to be more concise
            if (callSite.contains('package:mydatatools/')) {
              callSite = callSite.replaceAll('package:mydatatools/', '');
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

    return ['│ $emoji [$callSite] $message'];
  }
}

class AppLogger extends Logger {
  SendPort? sendPort;

  AppLogger(this.sendPort, {super.filter})
      : super(printer: ConcisePrinter());

  @override
  void log(Level level, dynamic message, {
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
