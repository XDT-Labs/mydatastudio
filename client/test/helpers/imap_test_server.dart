import 'dart:io';

import 'package:enough_mail/enough_mail.dart';

/// Helpers for integration tests against the disposable Dovecot container in
/// `test/integration/imap_server/` (start it with `make imap-test-up`).
const imapTestHost = '127.0.0.1';
const imapTestPort = 3143;
const imapTestPassword = 'testpass';
const imapTestUserAlice = 'alice@test.local';
const imapTestUserBob = 'bob@test.local';

/// Quick check so tests can skip (not fail) when Docker isn't running.
Future<bool> isImapTestServerAvailable() async {
  try {
    final socket = await Socket.connect(
      imapTestHost,
      imapTestPort,
      timeout: const Duration(milliseconds: 500),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Connects (plaintext, test only) and logs in. Caller must `logout()`.
Future<ImapClient> connectImapTestClient({
  String user = imapTestUserAlice,
  String password = imapTestPassword,
}) async {
  final client = ImapClient();
  await client.connectToServer(imapTestHost, imapTestPort, isSecure: false);
  await client.login(user, password);
  return client;
}

/// A message to APPEND. [messageId] is written verbatim (include the `<>`).
class SeedMessage {
  const SeedMessage({
    required this.messageId,
    required this.subject,
    required this.date,
    this.from = 'sender@example.com',
    this.to = 'alice@test.local',
    this.body = 'Test body',
    this.flags,
  });

  final String messageId;
  final String subject;
  final DateTime date;
  final String from;
  final String to;
  final String body;

  /// IMAP flags such as `\Seen`.
  final List<String>? flags;

  String toRfc822() => [
        'Message-ID: $messageId',
        'Date: ${DateCodec.encodeDate(date)}',
        'From: $from',
        'To: $to',
        'Subject: $subject',
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=utf-8',
        '',
        body,
        '',
      ].join('\r\n');
}

/// Appends [messages] to [mailbox] and returns their real UIDs in order,
/// read from each APPEND's `[APPENDUID <validity> <uid>]` response (UIDPLUS).
///
/// Throws a [StateError] if the server omits APPENDUID.
Future<List<int>> seedMessages(
  ImapClient client,
  String mailbox,
  List<SeedMessage> messages,
) async {
  final uids = <int>[];
  for (final m in messages) {
    final result = await client.appendMessageText(
      m.toRfc822(),
      flags: m.flags,
      targetMailboxPath: mailbox,
    );
    final ids = result.responseCodeAppendUid?.targetSequence.toList();
    if (ids == null || ids.length != 1) {
      throw StateError(
        'APPEND to $mailbox returned no usable APPENDUID '
        '(responseCode: ${result.responseCode})',
      );
    }
    uids.add(ids.single);
  }
  return uids;
}

/// Permanently removes the messages with the given [uids] (simulates a
/// server-side deletion).
Future<void> expungeUids(
  ImapClient client,
  String mailbox,
  List<int> uids,
) async {
  await client.selectMailboxByPath(mailbox);
  final sequence = MessageSequence.fromIds(uids, isUid: true);
  await client.uidMarkDeleted(sequence);
  await client.uidExpunge(sequence);
}

/// Removes every message in [mailbox]. UIDVALIDITY is unchanged; UIDNEXT keeps
/// growing, as on a real server.
Future<void> deleteAll(ImapClient client, String mailbox) async {
  final box = await client.selectMailboxByPath(mailbox);
  if (box.messagesExists == 0) return;
  await client.markDeleted(MessageSequence.fromAll());
  await client.expunge();
}
