import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:mydatastudio/app_logger.dart';

/// Captures what CustomLogOutput emits. ConsoleOutput calls print() once per
/// line, so a print-capturing zone gives us the post-truncation lines.
List<String> capture(OutputEvent event) {
  final lines = <String>[];
  runZoned(
    () => CustomLogOutput().output(event),
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

OutputEvent eventWith(Level level, List<String> lines) =>
    OutputEvent(LogEvent(level, 'msg'), lines);

void main() {
  group('CustomLogOutput truncation', () {
    test('caps non-error records to keep HTML bodies from flooding', () {
      // The reason this truncation exists: a single email body arriving as
      // hundreds of lines at debug level.
      final lines = capture(
        eventWith(Level.debug, List.generate(200, (i) => 'line $i')),
      );

      expect(lines.length, lessThan(200));
      expect(lines.last, contains('truncated'));
    });

    test('keeps an error record whole, message included', () {
      // PrettyPrinter puts the stack trace FIRST and the message after it, so a
      // ~14-line error box lost its message to the old 10-line cap — leaving a
      // stack trace with no statement of what failed. That is what made two
      // dropped PST emails cost an id-diff against the database to identify.
      final errorBox = [
        '┌─────────────────────────',
        for (var i = 0; i < 10; i++) '│ #$i  some.stack.frame',
        '├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄',
        '│ ⛔ PST Isolate: failed to apply email id=2101604 in FrontEnd',
        '└─────────────────────────',
      ];

      final lines = capture(eventWith(Level.error, errorBox));

      expect(
        lines.any((l) => l.contains('failed to apply email id=2101604')),
        isTrue,
        reason: 'the error message must survive truncation',
      );
      expect(lines.any((l) => l.contains('truncated')), isFalse);
    });

    test('keeps a long error line readable instead of clipping at 300', () {
      // Exception text carrying SQL or a path routinely passes 300 characters.
      final detail = 'x' * 1200;
      final lines = capture(eventWith(Level.error, ['SQLITE_BUSY: $detail']));

      expect(lines.single.length, greaterThan(1000));
    });

    test('still bounds a pathological error so it cannot fill the disk', () {
      final lines = capture(
        eventWith(Level.error, List.generate(500, (i) => 'frame $i')),
      );

      expect(lines.length, lessThan(500));
      expect(lines.last, contains('truncated'));
    });

    test('bounds a long non-error line', () {
      final lines = capture(eventWith(Level.info, ['y' * 5000]));

      expect(lines.single.length, lessThan(1000));
      expect(lines.single, contains('truncated'));
    });
  });
}
