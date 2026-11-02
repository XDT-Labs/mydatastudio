import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_connection_config.dart';
import 'package:mydatastudio/modules/email/services/scanners/imap_scanner_isolate.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';

void main() {
  authSelectionTests();
  group('ImapScannerIsolateWorker unit tests', () {
    test('localFolderName keeps server folder names inside the root', () {
      // Folder names come from the IMAP server; one must never steer
      // attachment writes outside the account's extraction directory.
      expect(ImapScannerIsolateWorker.localFolderName('INBOX'), 'INBOX');
      expect(ImapScannerIsolateWorker.localFolderName('Work/Projects'),
          'Work/Projects');
      expect(ImapScannerIsolateWorker.localFolderName('../../etc'), 'etc');
      expect(ImapScannerIsolateWorker.localFolderName('/abs/path'), 'abs/path');
      expect(ImapScannerIsolateWorker.localFolderName(r'..\..\x'), 'x');
      expect(ImapScannerIsolateWorker.localFolderName('..'), '_');
    });

    test('decodePartText decodes transfer encoding once and honors charset',
        () {
      // "=3D" in quoted-printable is a literal "="; decoding the result a
      // second time would turn the literal "=41" into "A".
      final qp = MimePart()
        ..addHeader('Content-Type', 'text/plain; charset=iso-8859-1')
        ..addHeader('Content-Transfer-Encoding', 'quoted-printable')
        ..mimeData = TextMimeData('caf=E9 =3D41\r\n', containsHeader: false);
      expect(ImapScannerIsolateWorker.decodePartText(qp)?.trim(), 'café =41');
    });

    test('mapMimeType correctly maps standard MIME types', () {
      expect(
        ImapScannerIsolateWorker.mapMimeType('image/jpeg'),
        FilesConstants.mimeTypeImage,
      );
      expect(
        ImapScannerIsolateWorker.mapMimeType('image/png'),
        FilesConstants.mimeTypeImage,
      );
      expect(
        ImapScannerIsolateWorker.mapMimeType('video/mp4'),
        FilesConstants.mimeTypeMovie,
      );
      expect(
        ImapScannerIsolateWorker.mapMimeType('audio/mpeg'),
        FilesConstants.mimeTypeMusic,
      );
      expect(
        ImapScannerIsolateWorker.mapMimeType('application/pdf'),
        FilesConstants.mimeTypePdf,
      );
      expect(
        ImapScannerIsolateWorker.mapMimeType('application/octet-stream'),
        FilesConstants.mimeTypeUnKnown,
      );
    });
  });
}

class _RecordingClient extends ImapClient {
  final calls = <String>[];

  @override
  Future<List<Capability>> login(String userName, String password) async {
    calls.add('login:$userName');
    return [];
  }

  @override
  Future<List<Capability>> authenticateWithOAuth2(
    String userName,
    String accessToken,
  ) async {
    calls.add('xoauth2:$userName');
    return [];
  }
}

Collection _col(String scanner, {String? providerId}) => Collection(
  id: 'c',
  name: 'me@outlook.com',
  path: 'p',
  type: 'email',
  scanner: scanner,
  scanStatus: 'idle',
  needsReAuth: false,
  emailProviderId: providerId,
  accessToken: 'tok',
  userId: 'me@yahoo.com',
);

void authSelectionTests() {
  group('authenticate picks the method from the provider authType', () {
    final logger = AppLogger(null);

    test('oauth2 (Outlook) uses XOAUTH2, never LOGIN', () async {
      final client = _RecordingClient();
      await ImapScannerIsolateWorker.authenticate(
        client,
        ImapConnectionConfig.fromCollection(_col('email.outlook')),
        logger,
      );
      expect(client.calls, ['xoauth2:me@outlook.com']);
    });

    test('app password (Yahoo) uses LOGIN, never XOAUTH2', () async {
      final client = _RecordingClient();
      await ImapScannerIsolateWorker.authenticate(
        client,
        ImapConnectionConfig.fromCollection(_col('email.yahoo')),
        logger,
      );
      expect(client.calls, ['login:me@yahoo.com']);
    });
  });
}
