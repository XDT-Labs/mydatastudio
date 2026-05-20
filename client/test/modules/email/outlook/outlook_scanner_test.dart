import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/services/scanners/outlook_scanner_isolate.dart';
import 'package:mydatatools/modules/files/files_constants.dart';

void main() {
  group('OutlookScannerIsolateWorker unit tests', () {
    test('getFolderType correctly identifies system folders', () {
      expect(OutlookScannerIsolateWorker.getFolderType('INBOX'), 'system');
      expect(OutlookScannerIsolateWorker.getFolderType('inbox'), 'system');
      expect(OutlookScannerIsolateWorker.getFolderType('SENT'), 'system');
      expect(OutlookScannerIsolateWorker.getFolderType('TRASH'), 'system');
      expect(OutlookScannerIsolateWorker.getFolderType('SPAM'), 'system');
      expect(OutlookScannerIsolateWorker.getFolderType('DRAFTS'), 'system');
    });

    test('getFolderType correctly identifies user folders', () {
      expect(OutlookScannerIsolateWorker.getFolderType('Work'), 'user');
      expect(OutlookScannerIsolateWorker.getFolderType('Projects'), 'user');
      expect(OutlookScannerIsolateWorker.getFolderType('Personal'), 'user');
    });

    test('mapMimeType correctly maps standard MIME types', () {
      expect(OutlookScannerIsolateWorker.mapMimeType('image/jpeg'), FilesConstants.mimeTypeImage);
      expect(OutlookScannerIsolateWorker.mapMimeType('image/png'), FilesConstants.mimeTypeImage);
      expect(OutlookScannerIsolateWorker.mapMimeType('video/mp4'), FilesConstants.mimeTypeMovie);
      expect(OutlookScannerIsolateWorker.mapMimeType('audio/mpeg'), FilesConstants.mimeTypeMusic);
      expect(OutlookScannerIsolateWorker.mapMimeType('application/pdf'), FilesConstants.mimeTypePdf);
      expect(OutlookScannerIsolateWorker.mapMimeType('application/octet-stream'), FilesConstants.mimeTypeUnKnown);
    });
  });
}
