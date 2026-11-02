import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/setup/imap_connection_tester.dart';

void main() {
  // The setup screen tells the user what to fix, so wrong credentials must not
  // be reported as an unreachable server (and vice versa).
  group('classifyImapConnectionError', () {
    test('socket and timeout errors mean the server is unreachable', () {
      expect(
        classifyImapConnectionError(const SocketException('no route')),
        ImapConnectionFailure.unreachable,
      );
      expect(
        classifyImapConnectionError(TimeoutException('slow')),
        ImapConnectionFailure.unreachable,
      );
      expect(
        classifyImapConnectionError(const HandshakeException('bad cert')),
        ImapConnectionFailure.unreachable,
      );
    });

    test('an ImapException after connecting means bad credentials', () {
      final e = ImapException(ImapClient(), 'NO [AUTHENTICATIONFAILED]');
      expect(
        classifyImapConnectionError(e),
        ImapConnectionFailure.badCredentials,
      );
    });

    test('anything else is unknown', () {
      expect(
        classifyImapConnectionError(StateError('x')),
        ImapConnectionFailure.unknown,
      );
    });
  });

  group('ImapConnectionResult', () {
    test('failure messages tell credentials and host problems apart', () {
      final creds = ImapConnectionResult.failure(
        ImapConnectionFailure.badCredentials,
      );
      final host = ImapConnectionResult.failure(
        ImapConnectionFailure.unreachable,
      );
      expect(creds.ok, isFalse);
      expect(creds.message, contains('password'));
      expect(host.message, contains('server'));
      expect(creds.message, isNot(equals(host.message)));
      expect(ImapConnectionResult.success().ok, isTrue);
    });
  });
}
