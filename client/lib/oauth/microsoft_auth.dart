import 'dart:convert';

import 'package:http/http.dart' as http;

/// Entra (Azure AD) client ID of the app registration bundled with this
/// build, supplied with `--dart-define=OUTLOOK_CLIENT_ID=<id>`. Empty when the
/// build was made without one; a client ID entered by the user in the app
/// takes precedence over it either way.
const String kBundledOutlookClientId = String.fromEnvironment(
  'OUTLOOK_CLIENT_ID',
);

/// Outlook / Microsoft 365 OAuth scopes. `profile` is kept beside `openid
/// email` because the sign-in reads `preferred_username` from the id_token to
/// find the mailbox address.
const List<String> kOutlookScopes = [
  'https://outlook.office.com/IMAP.AccessAsUser.All',
  'offline_access',
  'openid',
  'email',
  'profile',
];

const String _commonTokenEndpoint =
    'https://login.microsoftonline.com/common/oauth2/v2.0/token';

/// What went wrong when signing in to, or reading mail from, a Microsoft
/// account, as far as it can be told from the error text.
enum MicrosoftAuthProblem {
  /// The organisation's admin has to approve this app first.
  adminConsentRequired,

  /// Sign-in worked but the mailbox does not accept IMAP.
  imapDisabled,

  /// The stored sign-in is dead; the user has to sign in again.
  reauthRequired,

  /// Not recognised; show the raw error.
  unknown,
}

extension MicrosoftAuthProblemMessage on MicrosoftAuthProblem {
  /// Plain-language text for the user, written so it can be forwarded to IT
  /// as is. Null for [MicrosoftAuthProblem.unknown].
  String? get message => switch (this) {
    MicrosoftAuthProblem.adminConsentRequired =>
      'Your organisation requires an administrator to approve My Data Studio '
          'before you can sign in with this work or school account. Ask your '
          'IT administrator to grant consent for the application in Microsoft '
          'Entra ID (the delegated permissions are '
          'IMAP.AccessAsUser.All, offline_access, openid, email and profile), '
          'or to allow users to consent to it themselves. Then try again.',
    MicrosoftAuthProblem.imapDisabled =>
      'Microsoft accepted your sign-in, but the mailbox refused the IMAP '
          'connection. IMAP is probably turned off for this mailbox or '
          'organisation. Ask your IT administrator to enable IMAP for your '
          'mailbox (Exchange Online: Set-CASMailbox -Identity <your address> '
          '-ImapEnabled \$true) and to make sure it is not blocked by a '
          'Conditional Access policy or authentication policy. Then try '
          'again.',
    MicrosoftAuthProblem.reauthRequired =>
      'Microsoft no longer accepts the saved sign-in for this account (it '
          'expired or access was revoked). Sign in again to reconnect.',
    MicrosoftAuthProblem.unknown => null,
  };
}

/// Sorts the text of an OAuth or IMAP error into a [MicrosoftAuthProblem].
///
/// Pure string matching; pass whatever the failing layer gave you
/// (`error.toString()`, an `error_description`, a scan error message).
MicrosoftAuthProblem classifyMicrosoftAuthError(String raw) {
  final text = raw.toLowerCase();

  // AADSTS65001: consent not granted; AADSTS90094: admin consent required.
  final adminConsent =
      text.contains('aadsts65001') ||
      text.contains('aadsts90094') ||
      text.contains('admin approval') ||
      text.contains('admin consent') ||
      text.contains('need admin');
  if (adminConsent) return MicrosoftAuthProblem.adminConsentRequired;

  if (text.contains('invalid_grant')) {
    return MicrosoftAuthProblem.reauthRequired;
  }

  if (text.contains('authenticate failed')) {
    return MicrosoftAuthProblem.imapDisabled;
  }

  return MicrosoftAuthProblem.unknown;
}

/// A rejected token request. [isInvalidGrant] means the refresh token is dead
/// (revoked, expired, consent withdrawn) and the user must sign in again.
class MicrosoftAuthException implements Exception {
  final String error;
  final String? description;

  const MicrosoftAuthException(this.error, [this.description]);

  bool get isInvalidGrant => error == 'invalid_grant';

  @override
  String toString() =>
      'MicrosoftAuthException: $error${description == null ? '' : ' ($description)'}';
}

class MicrosoftTokenRefresh {
  final String accessToken;

  /// Microsoft rotates refresh tokens; store this one in place of the old one.
  final String refreshToken;
  final DateTime expiration;

  const MicrosoftTokenRefresh({
    required this.accessToken,
    required this.refreshToken,
    required this.expiration,
  });
}

/// Refreshes an Outlook access token as a public client: `client_id` and the
/// refresh token only, never a `client_secret`. Throws
/// [MicrosoftAuthException] when the request is rejected; callers should
/// flag the collection `needs_re_auth` when [MicrosoftAuthException.isInvalidGrant].
Future<MicrosoftTokenRefresh> refreshMicrosoftTokens({
  required String refreshToken,
  required String clientId,
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    final response = await client.post(
      Uri.parse(_commonTokenEndpoint),
      headers: {'Accept': 'application/json'},
      body: {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'refresh_token': refreshToken,
        'scope': kOutlookScopes.join(' '),
      },
    );

    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      body = const {};
    }

    final accessToken = body['access_token'] as String?;
    if (accessToken == null) {
      throw MicrosoftAuthException(
        body['error']?.toString() ?? 'http_${response.statusCode}',
        body['error_description']?.toString(),
      );
    }

    return MicrosoftTokenRefresh(
      accessToken: accessToken,
      refreshToken: body['refresh_token'] as String? ?? refreshToken,
      expiration: DateTime.now().toUtc().add(
        Duration(seconds: (body['expires_in'] as num?)?.toInt() ?? 3600),
      ),
    );
  } finally {
    if (httpClient == null) client.close();
  }
}
