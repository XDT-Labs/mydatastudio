import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/modules/email/services/imap/folder_role_mapper.dart';

void main() {
  test('special-use flag beats a misleading name', () {
    expect(
      folderRoleFor(name: 'Trash', flags: [MailboxFlag.sent]),
      FolderRole.sent,
    );
  });

  test('each special-use flag maps to its role', () {
    const cases = {
      MailboxFlag.sent: FolderRole.sent,
      MailboxFlag.drafts: FolderRole.drafts,
      MailboxFlag.trash: FolderRole.trash,
      MailboxFlag.junk: FolderRole.junk,
      MailboxFlag.archive: FolderRole.archive,
      MailboxFlag.all: FolderRole.all,
      MailboxFlag.flagged: FolderRole.flagged,
      MailboxFlag.inbox: FolderRole.inbox,
    };
    cases.forEach((flag, role) {
      expect(folderRoleFor(name: 'x', flags: [flag]), role);
    });
  });

  test('INBOX is recognised by name in any case', () {
    expect(folderRoleFor(name: 'INBOX'), FolderRole.inbox);
    expect(folderRoleFor(name: 'Inbox'), FolderRole.inbox);
  });

  test('a nested folder named Inbox is not the inbox', () {
    expect(folderRoleFor(name: 'Inbox', path: 'Work/Inbox'), FolderRole.user);
  });

  test('provider hints cover servers without special-use flags', () {
    expect(
      folderRoleFor(
        name: 'Bulk Mail',
        provider: EmailProviderRegistry.yahoo,
      ),
      FolderRole.junk,
    );
    expect(
      folderRoleFor(
        name: 'Junk Email',
        provider: EmailProviderRegistry.outlook,
      ),
      FolderRole.junk,
    );
    expect(
      folderRoleFor(
        name: 'Deleted Items',
        provider: EmailProviderRegistry.outlook,
      ),
      FolderRole.trash,
    );
    expect(
      folderRoleFor(
        name: 'Important',
        path: '[Gmail]/Important',
        provider: EmailProviderRegistry.gmail,
      ),
      FolderRole.important,
    );
  });

  test('provider hints do not leak to other providers', () {
    expect(folderRoleFor(name: 'Bulk Mail'), FolderRole.user);
  });

  test('generic English fallback', () {
    expect(folderRoleFor(name: 'Sent Messages'), FolderRole.sent);
    expect(folderRoleFor(name: 'Deleted Messages'), FolderRole.trash);
    expect(folderRoleFor(name: 'spam'), FolderRole.junk);
    expect(folderRoleFor(name: 'Drafts'), FolderRole.drafts);
    expect(folderRoleFor(name: 'Archive'), FolderRole.archive);
  });

  test('anything else is user', () {
    expect(folderRoleFor(name: 'Receipts'), FolderRole.user);
  });

  test('db serialization round-trips; legacy and null map to user', () {
    for (final r in FolderRole.values) {
      expect(FolderRole.fromDb(r.name), r);
    }
    expect(FolderRole.fromDb('system'), FolderRole.user);
    expect(FolderRole.fromDb(null), FolderRole.user);
    expect(FolderRole.user.name, 'user'); // matches the column default
  });
}
