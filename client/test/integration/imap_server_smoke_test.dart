@Tags(['imap'])
library;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/imap_test_server.dart';

void main() {
  late bool available;
  ImapClient? client;

  setUpAll(() async {
    available = await isImapTestServerAvailable();
  });

  setUp(() async {
    if (!available) return;
    client = await connectImapTestClient();
    await deleteAll(client!, 'INBOX');
  });

  tearDown(() async {
    try {
      await client?.logout();
    } catch (_) {}
    client = null;
  });

  const skipReason =
      'IMAP test server not running on 127.0.0.1:3143 (run `make imap-test-up`)';

  // `skip` is evaluated at registration, before setUpAll, so probe lazily.
  void imapTest(String name, Future<void> Function(ImapClient c) body) {
    test(name, () async {
      if (!available) {
        markTestSkipped(skipReason);
        return;
      }
      await body(client!);
    }, tags: 'imap');
  }

  imapTest('login works and server advertises CONDSTORE + SPECIAL-USE',
      (c) async {
    final caps = c.serverInfo.capabilities ?? [];
    final names = caps.map((x) => x.name).toList();
    expect(names, containsAll(['CONDSTORE', 'SPECIAL-USE', 'UIDPLUS']));
  });

  imapTest('LIST returns special-use flags', (c) async {
    final boxes = await c.listMailboxes(recursive: true);
    final byName = {for (final b in boxes) b.name: b};
    expect(byName['Sent']!.isSent, isTrue);
    expect(byName['Drafts']!.isDrafts, isTrue);
    expect(byName['Trash']!.isTrash, isTrue);
    expect(byName['Junk']!.isJunk, isTrue);
    expect(byName['Archive']!.isArchive, isTrue);
    expect(byName['Sent Items']!.isSent, isTrue);
    expect(byName['Papierkorb']!.isTrash, isTrue);
  });

  imapTest('SELECT reports UIDVALIDITY, UIDNEXT and HIGHESTMODSEQ',
      (c) async {
    final box = await c.selectMailboxByPath('INBOX', enableCondStore: true);
    expect(box.uidValidity, isNotNull);
    expect(box.uidNext, isNotNull);
    expect(box.highestModSequence, isNotNull);
  });

  imapTest('seed then fetch by UID, then expunge removes it', (c) async {
    final msgs = [
      SeedMessage(
        messageId: '<one@test.local>',
        subject: 'One',
        date: DateTime.utc(2024, 1, 2, 3, 4, 5),
      ),
      SeedMessage(
        messageId: '<two@test.local>',
        subject: 'Two',
        date: DateTime.utc(2024, 1, 3),
        flags: [MessageFlags.seen],
      ),
    ];
    final uids = await seedMessages(c, 'INBOX', msgs);

    var fetched = await c.uidFetchMessages(
      MessageSequence.fromIds(uids, isUid: true),
      '(UID FLAGS ENVELOPE)',
    );
    expect(fetched.messages.map((m) => m.uid), uids);
    expect(fetched.messages.map((m) => m.envelope?.messageId),
        ['<one@test.local>', '<two@test.local>']);
    expect(fetched.messages[1].isSeen, isTrue);

    await expungeUids(c, 'INBOX', [uids.first]);
    fetched = await c.uidFetchMessages(
      MessageSequence.fromIds(uids, isUid: true),
      '(UID)',
    );
    expect(fetched.messages.map((m) => m.uid), [uids.last]);
  });
}
