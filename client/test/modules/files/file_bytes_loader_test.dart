// Permanent vs transient read failures — search plan §18k.
//
// The distinction exists because the two call for opposite responses. A file
// on an unmounted NAS will read fine later, so the source backs off and the
// file keeps its retry budget. A Google Doc has no bytes to read and never
// will, so backing the source off stalls every other file behind a condition
// that has nothing to do with the source being reachable.
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/utilities/file_bytes_loader.dart';

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
    });
  });
}
