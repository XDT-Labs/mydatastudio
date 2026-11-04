import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_connection_config.dart';
import 'package:mydatastudio/oauth/microsoft_auth.dart';

/// Refresh this long before the access token actually expires.
const Duration kOutlookRefreshMargin = Duration(minutes: 5);

typedef OutlookTokenRefreshFn =
    Future<MicrosoftTokenRefresh> Function({
      required String refreshToken,
      required String clientId,
    });

/// Whether [expiration] is close enough that the token must be renewed.
/// An unknown expiration is treated as expired.
bool outlookTokenNeedsRefresh(
  DateTime? expiration, {
  DateTime? now,
  Duration margin = kOutlookRefreshMargin,
}) {
  if (expiration == null) return true;
  return (now ?? DateTime.now().toUtc()).isAfter(expiration.subtract(margin));
}

/// Returns [config] with a valid Outlook access token, refreshing and
/// persisting (via [persist]) first when the stored one is expired or about to
/// be. Other providers and password auth pass through untouched.
///
/// Throws [MicrosoftAuthException] when Microsoft rejects the refresh
/// (`isInvalidGrant` = the user must sign in again); other errors (network)
/// propagate as they are.
Future<ImapConnectionConfig> ensureFreshOutlookToken({
  required Collection collection,
  required ImapConnectionConfig config,
  required Future<String> Function() clientId,
  required Future<void> Function(MicrosoftTokenRefresh tokens) persist,
  OutlookTokenRefreshFn refresh = _defaultRefresh,
  DateTime? now,
}) async {
  if (config.provider.id != 'outlook' ||
      config.authType != EmailAuthType.oauth2) {
    return config;
  }
  if (!outlookTokenNeedsRefresh(collection.expiration, now: now)) {
    return config;
  }
  final refreshToken = collection.refreshToken;
  if (refreshToken == null || refreshToken.isEmpty) {
    throw const MicrosoftAuthException(
      'invalid_grant',
      'no refresh token stored',
    );
  }

  final tokens = await refresh(
    refreshToken: refreshToken,
    clientId: await clientId(),
  );
  await persist(tokens);

  return ImapConnectionConfig(
    provider: config.provider,
    host: config.host,
    port: config.port,
    security: config.security,
    authType: config.authType,
    username: config.username,
    secret: tokens.accessToken,
  );
}

Future<MicrosoftTokenRefresh> _defaultRefresh({
  required String refreshToken,
  required String clientId,
}) => refreshMicrosoftTokens(refreshToken: refreshToken, clientId: clientId);
