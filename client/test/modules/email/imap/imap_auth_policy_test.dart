import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_auth_policy.dart';

void main() {
  // Flagging needs_re_auth makes the user reconnect, so it must only follow a
  // refusal that clearly blames the credential, not rate limits or outages.
  group('isCredentialRejection', () {
    test('recognises real-looking credential refusals', () {
      for (final text in [
        'NO [AUTHENTICATIONFAILED] Authentication failed.', // Dovecot
        'NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)', // Gmail
        'NO [AUTHENTICATIONFAILED] LOGIN failed', // Yahoo
        'a1 NO LOGIN failed.', // Yahoo, no code
        'NO Invalid login or password', // iCloud / others
        'NO [AUTHENTICATIONFAILED] Invalid credentials', // iCloud, Yandex
        'no [authenticationfailed]',
      ]) {
        expect(isCredentialRejection(text), isTrue, reason: text);
      }
    });

    test('temporary trouble and unknown text are not credential errors', () {
      for (final text in [
        'NO [UNAVAILABLE] Temporary authentication failure', // beats wording
        'NO [LIMIT] Too many login attempts, try later',
        'NO [INUSE] Mailbox is locked',
        'NO Server busy, try again later',
        'BYE Service temporarily unavailable',
        '',
      ]) {
        expect(isCredentialRejection(text), isFalse, reason: text);
      }
    });
  });

  group('decideAuthFailureAction', () {
    const rejected = 'NO [AUTHENTICATIONFAILED] Invalid credentials';

    test('a clear rejection flags re-auth', () {
      expect(
        decideAuthFailureAction(providerId: 'icloud', serverText: rejected),
        AuthFailureAction.flagReAuth,
      );
    });

    test('an unclear refusal is retried, never flagged', () {
      expect(
        decideAuthFailureAction(
          providerId: 'yahoo',
          serverText: 'NO [LIMIT] Too many connections',
        ),
        AuthFailureAction.retryLater,
      );
    });

    // A new Yandex app password can take hours to activate; flagging in that
    // window would make the user redo a setup that is actually fine.
    test('Yandex is retried within 3 hours of creation, then flagged', () {
      final created = DateTime(2026, 1, 1, 10);
      expect(
        decideAuthFailureAction(
          providerId: 'yandex',
          serverText: rejected,
          dateCreated: created,
          now: created.add(const Duration(hours: 2, minutes: 59)),
        ),
        AuthFailureAction.retryLater,
      );
      expect(
        decideAuthFailureAction(
          providerId: 'yandex',
          serverText: rejected,
          dateCreated: created,
          now: created.add(const Duration(hours: 3, minutes: 1)),
        ),
        AuthFailureAction.flagReAuth,
      );
    });

    test('Yandex with no creation date (legacy row) gets normal handling', () {
      expect(
        decideAuthFailureAction(providerId: 'yandex', serverText: rejected),
        AuthFailureAction.flagReAuth,
      );
    });

    test('the Yandex window does not apply to other providers', () {
      expect(
        decideAuthFailureAction(
          providerId: 'fastmail',
          serverText: rejected,
          dateCreated: DateTime.now(),
        ),
        AuthFailureAction.flagReAuth,
      );
    });
  });
}
