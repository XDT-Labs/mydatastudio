// Permanent vs transient read failures — search plan §18k.
//
// The distinction exists because the two call for opposite responses. A file
// on an unmounted NAS will read fine later, so the source backs off and the
// file keeps its retry budget. A Google Doc has no bytes to read and never
// will, so backing the source off stalls every other file behind a condition
// that has nothing to do with the source being reachable.
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/utilities/file_bytes_loader.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

void main() {
  group('isGoogleNativeFormat', () {
    test('recognises the Workspace editors', () {
      expect(
        FileBytesLoader.isGoogleNativeFormat(
          'application/vnd.google-apps.document',
        ),
        isTrue,
      );
      expect(
        FileBytesLoader.isGoogleNativeFormat(
          'application/vnd.google-apps.spreadsheet',
        ),
        isTrue,
      );
    });

    test('excludes folders, which are not documents at all', () {
      expect(
        FileBytesLoader.isGoogleNativeFormat(
          'application/vnd.google-apps.folder',
        ),
        isFalse,
      );
    });

    test('leaves ordinary Drive files alone', () {
      // A PDF or Word file *stored in* Drive downloads normally — only the
      // native editor formats have no byte representation.
      expect(FileBytesLoader.isGoogleNativeFormat('application/pdf'), isFalse);
      expect(FileBytesLoader.isGoogleNativeFormat('image/jpeg'), isFalse);
      expect(FileBytesLoader.isGoogleNativeFormat(null), isFalse);
    });
  });

  group('Workspace export targets', () {
    test('Docs and Sheets export to formats docling reads natively', () {
      // DOCX/XLSX rather than PDF: docling reads both with no model download,
      // so an exported Workspace file chunks through the same path as any
      // other document, heading paths included (§18k).
      expect(
        FileBytesLoader.exportTargetFor(
          'application/vnd.google-apps.document',
        )?.extension,
        'docx',
      );
      expect(
        FileBytesLoader.exportTargetFor(
          'application/vnd.google-apps.spreadsheet',
        )?.extension,
        'xlsx',
      );
    });

    test('has no target for Workspace types that are not documents', () {
      // Forms, Drawings and Sites have no useful document export; asking for
      // one is a round-trip that can only fail.
      for (final kind in ['form', 'drawing', 'site', 'shortcut']) {
        expect(
          FileBytesLoader.exportTargetFor('application/vnd.google-apps.$kind'),
          isNull,
          reason: kind,
        );
      }
    });

    test('has no target for ordinary files, which download directly', () {
      expect(FileBytesLoader.exportTargetFor('application/pdf'), isNull);
      expect(FileBytesLoader.exportTargetFor(null), isNull);
    });

    test('every queued Workspace type has somewhere to be exported to', () {
      // The queue lists these as a SQL literal and the loader as a map; if
      // they drift, a file is offered forever and never readable.
      for (final type in DatabaseRepository.exportableWorkspaceTypes) {
        expect(FileBytesLoader.exportTargetFor(type), isNotNull, reason: type);
      }
    });
  });

  group('FileBytes outcomes', () {
    test('a permanent failure is distinguishable from a transient one', () {
      const permanent = FileBytes.permanent();
      const transient = FileBytes.transient();

      expect(permanent.ok, isFalse);
      expect(transient.ok, isFalse);
      expect(permanent.permanent, isTrue);
      expect(transient.permanent, isFalse,
          reason: 'an outage must not spend a retry budget');
    });

    test('success is never permanent', () {
      const result = FileBytes.ok([1, 2, 3]);
      expect(result.ok, isTrue);
      expect(result.permanent, isFalse);
      expect(result.bytes, [1, 2, 3]);
      expect(result.filenameHint, isNull,
          reason: 'only an export renames what it fetched');
    });

    test('an export carries the name its bytes should be read as', () {
      const result = FileBytes.ok([1], filenameHint: 'Plan.md.docx');
      expect(result.filenameHint, 'Plan.md.docx',
          reason: 'DOCX and XLSX share a ZIP signature, so the extension is '
              'the only thing that tells the extractor which one it has');
    });
  });
}
