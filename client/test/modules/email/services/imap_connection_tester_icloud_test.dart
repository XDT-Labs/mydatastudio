import 'package:enough_mail/enough_mail.dart';
// ignore: implementation_imports
import 'package:enough_mail/src/private/util/client_base.dart' show ConnectionInfo;
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/setup/imap_connection_tester.dart';

/// Accepts only the logins in [accepted]; records every attempt.
class _FakeImapClient extends ImapClient {
  _FakeImapClient(this.accepted, this.attempts) : super(isLogEnabled: false);
  final Set<String> accepted;
  final List<String> attempts;

  @override
  Future<ConnectionInfo> connectToServer(
    String host,
    int port, {
    bool isSecure = true,
    Duration? timeout,
  }) async => ConnectionInfo(host, port, isSecure: isSecure);

  @override
  Future<List<Capability>> login(String userName, String password) async {
    attempts.add(userName);
    if (!accepted.contains(userName)) {
      throw ImapException(this, 'NO [AUTHENTICATIONFAILED]');
    }
    return <Capability>[];
  }

  @override
  Future<void> disconnect() async {}
}

void main() {
  ImapConnectionRequest request(String provider, String username) =>
      ImapConnectionRequest(
        host: 'imap.mail.me.com',
        port: 993,
        security: ImapSecurity.ssl,
        username: username,
        password: 'app-pw',
        providerId: provider,
      );

  EnoughMailImapConnectionTester testerAccepting(
    Set<String> accepted,
    List<String> attempts,
  ) => EnoughMailImapConnectionTester(
    clientFactory: () => _FakeImapClient(accepted, attempts),
  );

  // Some iCloud accounts only log in with the part before the '@'; the saved
  // account has to use whichever name worked or every later sync would fail.
  group('iCloud username fallback', () {
    test('retries with the local part and reports it as the username',
        () async {
      final attempts = <String>[];
      final result = await testerAccepting({'jane'}, attempts).test(
        request('icloud', 'jane@icloud.com'),
      );
      expect(result.ok, isTrue);
      expect(result.resolvedUsername, 'jane');
      expect(attempts, ['jane@icloud.com', 'jane']);
    });

    test('full address working means no retry and no override', () async {
      final attempts = <String>[];
      final result = await testerAccepting({'jane@icloud.com'}, attempts).test(
        request('icloud', 'jane@icloud.com'),
      );
      expect(result.ok, isTrue);
      expect(result.resolvedUsername, isNull);
      expect(attempts, ['jane@icloud.com']);
    });

    test('both rejected: one retry only, original failure reported', () async {
      final attempts = <String>[];
      final result = await testerAccepting({}, attempts).test(
        request('icloud', 'jane@icloud.com'),
      );
      expect(result.ok, isFalse);
      expect(result.failure, ImapConnectionFailure.badCredentials);
      expect(attempts, ['jane@icloud.com', 'jane']);
    });

    test('other providers never retry with the local part', () async {
      final attempts = <String>[];
      final result = await testerAccepting({'jane'}, attempts).test(
        request('fastmail', 'jane@fastmail.com'),
      );
      expect(result.ok, isFalse);
      expect(attempts, ['jane@fastmail.com']);
    });
  });
}
