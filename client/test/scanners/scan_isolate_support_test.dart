import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/scanners/scan_isolate_support.dart';

void main() {
  group('relayIsolateLog', () {
    test('relays non-log messages returning false', () {
      final logger = AppLogger(null);
      expect(relayIsolateLog(logger, {'type': 'refresh'}, '[Test]'), isFalse);
      expect(relayIsolateLog(logger, 'not a map', '[Test]'), isFalse);
    });

    test('relays error log with String stack trace without throwing type error', () {
      final logger = AppLogger(null);
      final logMessage = {
        'type': 'log',
        'level': 'error',
        'message': 'Failed to parse message',
        'error': 'FormatException: Invalid UTF-8',
        'stackTrace': '#0 main (file:///test.dart:10:5)\n#1 isolate (file:///worker.dart:20:3)',
      };

      expect(() => relayIsolateLog(logger, logMessage, '[TestScan]'), returnsNormally);
      expect(relayIsolateLog(logger, logMessage, '[TestScan]'), isTrue);
    });

    test('relays info log successfully', () {
      final logger = AppLogger(null);
      final logMessage = {
        'type': 'log',
        'level': 'info',
        'message': 'Scan started',
      };

      expect(relayIsolateLog(logger, logMessage, '[TestScan]'), isTrue);
    });
  });
}
