import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/gmail/v1.dart';
import 'package:mydatastudio/modules/email/services/scanners/gmail_scanner_isolate.dart';

void main() {
  group('GmailScannerIsolateWorker mapping tests', () {
    test('mapLabelToFolder converts Gmail Label to EmailFolder correctly', () {
      final label = Label(
        id: 'INBOX',
        name: 'Inbox',
        type: 'system',
        messagesTotal: 100,
        messagesUnread: 5,
      );

      final folder = GmailScannerIsolateWorker.mapLabelToFolder(label, 'col1');

      expect(folder.id, 'INBOX');
      expect(folder.collectionId, 'col1');
      expect(folder.name, 'Inbox');
      expect(folder.type, 'system');
      expect(folder.messagesTotal, 100);
      expect(folder.messagesUnread, 5);
    });

    test('mapLabelToFolder handles user labels correctly', () {
      final label = Label(id: 'Label_1', name: 'Work', type: 'user');

      final folder = GmailScannerIsolateWorker.mapLabelToFolder(label, 'col1');

      expect(folder.id, 'Label_1');
      expect(folder.type, 'user');
    });
  });
}
