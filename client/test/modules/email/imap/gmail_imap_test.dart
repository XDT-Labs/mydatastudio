import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/modules/email/services/imap/folder_role_mapper.dart';
import 'package:mydatastudio/modules/email/services/imap/gmail_imap.dart';

Mailbox box(String path, [List<MailboxFlag> flags = const []]) => Mailbox(
  encodedName: path.split('/').last,
  encodedPath: path,
  flags: [...flags],
  pathSeparator: '/',
);

void main() {
  group('gmailAllMailPath', () {
    final gmail = EmailProviderRegistry.gmail;

    test('found by the SPECIAL-USE \\All flag, whatever its name', () {
      expect(
        gmailAllMailPath([
          box('INBOX'),
          box('[Gmail]/Alle Nachrichten', [MailboxFlag.all]),
        ], provider: gmail),
        '[Gmail]/Alle Nachrichten',
      );
    });

    test('falls back to the English name hint', () {
      expect(
        gmailAllMailPath([
          box('INBOX'),
          box('[Gmail]/All Mail'),
        ], provider: gmail),
        '[Gmail]/All Mail',
      );
    });

    test('null when the account hides All Mail from IMAP', () {
      expect(
        gmailAllMailPath([box('INBOX'), box('Work')], provider: gmail),
        isNull,
      );
    });
  });

  group('parseGmailFetchLine', () {
    test('reads ids and unquoted system labels', () {
      final m =
          parseGmailFetchLine(
            r'* 12 FETCH (UID 4711 X-GM-MSGID 1278455344230334865 '
            r'X-GM-THRID 1278455344230334865 '
            r'X-GM-LABELS (\Inbox \Sent \Important \Starred))',
          )!;
      expect(m.uid, 4711);
      expect(m.msgId, '1278455344230334865');
      expect(m.threadId, '1278455344230334865');
      expect(m.labels, [r'\Inbox', r'\Sent', r'\Important', r'\Starred']);
    });

    test('quoted labels keep their spaces; quoted system label unescapes', () {
      final m =
          parseGmailFetchLine(
            r'12 FETCH (X-GM-LABELS ("\\Inbox" "Project X" Work/Receipts '
            r'"say \"hi\"") UID 9)',
          )!;
      expect(m.uid, 9);
      expect(m.labels, [r'\Inbox', 'Project X', 'Work/Receipts', 'say "hi"']);
    });

    test('decodes modified UTF-7 label names', () {
      final m =
          parseGmailFetchLine(
            r'1 FETCH (UID 5 X-GM-LABELS ("Caf&AOk-" "&AOQ-rzte"))',
          )!;
      expect(m.labels, ['Café', 'ärzte']);
    });

    test('empty label list and CONDSTORE MODSEQ are fine', () {
      final m =
          parseGmailFetchLine(
            r'3 FETCH (UID 77 MODSEQ (123456) X-GM-LABELS ())',
          )!;
      expect(m.uid, 77);
      expect(m.labels, isEmpty);
    });

    test('a response without X-GM-LABELS has null labels', () {
      final m = parseGmailFetchLine('3 FETCH (UID 77 X-GM-THRID 5)')!;
      expect(m.labels, isNull);
      expect(m.threadId, '5');
    });

    test('lines that are not a FETCH with a UID are ignored', () {
      expect(parseGmailFetchLine('5 EXISTS'), isNull);
      expect(parseGmailFetchLine('3 FETCH (FLAGS (\\Seen))'), isNull);
    });
  });

  test('sequences render as IMAP sets in the raw FETCH command', () {
    expect(MessageSequence.fromIds([1, 2, 5], isUid: true).toString(), '1:2,5');
    expect(
      MessageSequence.fromRange(1, 40, isUidSequence: true).toString(),
      '1:40',
    );
  });

  group('isGmailDownloadLimitError', () {
    for (final text in [
      'NO [OVERQUOTA] Account exceeded command or bandwidth limits. (Failure)',
      'ImapException: Account exceeded command or bandwidth limits.',
      'NO Download limit exceeded',
      'a5 NO [overquota] try later',
    ]) {
      test(
        'detects: $text',
        () => expect(isGmailDownloadLimitError(text), isTrue),
      );
    }

    test('does not flag ordinary failures', () {
      expect(
        isGmailDownloadLimitError('NO [AUTHENTICATIONFAILED] bad'),
        isFalse,
      );
      expect(isGmailDownloadLimitError('Connection reset by peer'), isFalse);
      expect(isGmailDownloadLimitError('BAD Could not parse command'), isFalse);
    });
  });

  group('GmailLabelMapper', () {
    GmailLabelMapper mapper([
      List<({String path, FolderRole role})> extra = const [],
    ]) => GmailLabelMapper(
      allMailPath: '[Gmail]/All Mail',
      folders: [
        (path: 'INBOX', role: FolderRole.inbox),
        (path: '[Gmail]/All Mail', role: FolderRole.all),
        ...extra,
      ],
    );

    test('system labels map to the system folders', () {
      expect(
        mapper().foldersFor([
          r'\Inbox',
          r'\Sent',
          r'\Starred',
          r'\Important',
          r'\Draft',
        ]),
        [
          'INBOX',
          '[Gmail]/Sent Mail',
          '[Gmail]/Starred',
          '[Gmail]/Important',
          '[Gmail]/Drafts',
        ],
      );
    });

    test('a localised Sent folder from LIST wins over the English default', () {
      final m = mapper([(path: '[Gmail]/Gesendet', role: FolderRole.sent)]);
      expect(m.foldersFor([r'\Sent']), ['[Gmail]/Gesendet']);
    });

    test('user labels are their own folder; duplicates collapse', () {
      expect(mapper().foldersFor(['Project X', 'Work/Receipts', 'Project X']), [
        'Project X',
        'Work/Receipts',
      ]);
    });

    test('Trash, Spam, All Mail and unmappable names are not memberships', () {
      expect(
        mapper().foldersFor([
          r'\Trash',
          r'\Spam',
          r'\All',
          '[Gmail]/All Mail',
          'a,b',
          r'\Unknown',
        ]),
        isEmpty,
      );
    });
  });
}
