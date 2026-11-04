import 'package:enough_mail/enough_mail.dart';

/// The server answered and refused the login (as opposed to the network
/// failing). Wraps the original [ImapException] so the scanner can tell a
/// rejected credential from any other scan failure.
class ImapAuthFailure implements Exception {
  final ImapException cause;
  const ImapAuthFailure(this.cause);

  @override
  String toString() => 'ImapAuthFailure: $cause';
}

enum AuthFailureAction {
  /// The credential is dead: set `needs_re_auth` so the user is prompted.
  flagReAuth,

  /// Probably not dead yet: record a scan error and let the next scheduled
  /// sync try again.
  retryLater,
}

/// How long a new Yandex app password may take to start working (the provider
/// documents 2-3 hours).
const Duration kYandexActivationWindow = Duration(hours: 3);

/// Whether the server's login refusal clearly says the credential is wrong,
/// as opposed to rate limiting, maintenance or other temporary trouble.
///
/// Matches the RFC 5530 `[AUTHENTICATIONFAILED]` response code or the common
/// wordings servers use without it. `[UNAVAILABLE]`, `[LIMIT]`, `[INUSE]` and
/// unrecognised text are not credential rejections.
bool isCredentialRejection(String serverText) {
  final text = serverText.toLowerCase();
  if (text.contains('[unavailable]') ||
      text.contains('[limit]') ||
      text.contains('[inuse]')) {
    return false;
  }
  return text.contains('[authenticationfailed]') ||
      text.contains('authentication failed') ||
      text.contains('invalid credentials') ||
      text.contains('login failed') ||
      text.contains('invalid login or password');
}

/// What to do when the server rejects the login.
///
/// Only a clear credential rejection can flag `needs_re_auth`. A new Yandex
/// app password can take hours to activate, so a rejection within
/// [kYandexActivationWindow] of [dateCreated] is retried instead. A null
/// [dateCreated] (a collection from before the column existed) gets the
/// normal handling.
AuthFailureAction decideAuthFailureAction({
  required String providerId,
  required String serverText,
  DateTime? dateCreated,
  DateTime? now,
}) {
  if (!isCredentialRejection(serverText)) return AuthFailureAction.retryLater;
  if (providerId == 'yandex' &&
      dateCreated != null &&
      (now ?? DateTime.now()).difference(dateCreated) <=
          kYandexActivationWindow) {
    return AuthFailureAction.retryLater;
  }
  return AuthFailureAction.flagReAuth;
}
