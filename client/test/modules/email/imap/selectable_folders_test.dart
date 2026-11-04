import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/modules/email/services/scanners/imap_scanner_isolate.dart';

Mailbox box(String path, [List<MailboxFlag> flags = const []]) => Mailbox(
  encodedName: path,
  encodedPath: path,
  flags: [...flags],
  pathSeparator: '/',
);

void main() {
  // Junk and Trash are noise in a personal archive and, for spam, a place
  // where hostile content lands: the default is to never visit them.
  test('Junk and Trash are not synced, by SPECIAL-USE flag', () {
    final paths = ImapScannerIsolateWorker.selectableFolderPaths([
      box('Archive', [MailboxFlag.archive]),
      box('Papierkorb', [MailboxFlag.trash]),
      box('Spam!', [MailboxFlag.junk]),
      box('INBOX', [MailboxFlag.inbox]),
    ]);
    expect(paths, ['INBOX', 'Archive']);
  });

  test('Junk and Trash are not synced, by provider name hint', () {
    final yahoo = EmailProviderRegistry.byId('yahoo');
    final paths = ImapScannerIsolateWorker.selectableFolderPaths([
      box('INBOX'),
      box('Bulk Mail'),
      box('Trash'),
      box('Work'),
    ], provider: yahoo);
    expect(paths, ['INBOX', 'Work']);
  });

  test('a user folder merely named like spam by a non-hint is kept', () {
    final paths = ImapScannerIsolateWorker.selectableFolderPaths([
      box('INBOX'),
      box('Spamalot'),
    ]);
    expect(paths, ['INBOX', 'Spamalot']);
  });

  test('Noselect and NonExistent containers are not synced', () {
    final paths = ImapScannerIsolateWorker.selectableFolderPaths([
      box('INBOX'),
      box('Container', [MailboxFlag.noSelect]),
      box('Ghost', [MailboxFlag.nonExistent]),
    ]);
    expect(paths, ['INBOX']);
  });
}
