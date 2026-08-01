import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';
import 'package:path/path.dart' as p;

void main() {
  group('isPathWithinExtractionRoot', () {
    late String extractionRoot;

    setUp(() {
      extractionRoot = io.Directory.systemTemp
          .createTempSync('pst_extraction_root')
          .path;
    });

    tearDown(() {
      io.Directory(extractionRoot).deleteSync(recursive: true);
    });

    test('accepts a path inside the extraction root', () {
      final attPath = p.join(extractionRoot, 'attachments', 'file.png');
      expect(isPathWithinExtractionRoot(attPath, extractionRoot), isTrue);
    });

    test('accepts the extraction root itself', () {
      expect(isPathWithinExtractionRoot(extractionRoot, extractionRoot), isTrue);
    });

    test('rejects a sibling directory that shares the root as a string prefix', () {
      // e.g. extractionRoot = ".../extraction", evil sibling = ".../extraction-evil"
      final evilSibling = '$extractionRoot-evil';
      final attPath = p.join(evilSibling, 'file.png');
      expect(isPathWithinExtractionRoot(attPath, extractionRoot), isFalse);
    });

    test('rejects a path outside the extraction root entirely', () {
      final outside = io.Directory.systemTemp.createTempSync('pst_outside').path;
      addTearDown(() => io.Directory(outside).deleteSync(recursive: true));
      final attPath = p.join(outside, 'file.png');
      expect(isPathWithinExtractionRoot(attPath, extractionRoot), isFalse);
    });

    test('rejects a lexical parent-directory traversal out of the root', () {
      final attPath = p.join(extractionRoot, '..', 'evil', 'file.png');
      expect(isPathWithinExtractionRoot(attPath, extractionRoot), isFalse);
    });
  });
}
