import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';

/// Thrown when a collection cannot be turned into a usable IMAP connection.
class ImapConfigException implements Exception {
  final String message;
  const ImapConfigException(this.message);

  @override
  String toString() => 'ImapConfigException: $message';
}

/// Everything the scanner needs to connect and authenticate, resolved from a
/// [Collection]. Holds the secret, so never log it.
class ImapConnectionConfig {
  final EmailProvider provider;
  final String host;
  final int port;
  final ImapSecurity security;
  final EmailAuthType authType;

  /// Login name (password auth) or XOAUTH2 user (oauth2).
  final String username;

  /// App password, password or OAuth access token.
  final String secret;

  const ImapConnectionConfig({
    required this.provider,
    required this.host,
    required this.port,
    required this.security,
    required this.authType,
    required this.username,
    required this.secret,
  });

  /// Resolution order: `emailProviderId` -> registry; else the legacy
  /// `scanner` value (`email.yahoo` / `email.outlook`). The `other` provider
  /// takes host/port/security from `Collection.imapSettings`.
  ///
  /// Throws [ImapConfigException] rather than guessing.
  factory ImapConnectionConfig.fromCollection(Collection collection) {
    final providerId = collection.emailProviderId;
    var provider =
        providerId != null
            ? EmailProviderRegistry.byId(providerId)
            : EmailProviderRegistry.forLegacyScanner(collection.scanner);
    if (provider == null) {
      throw ImapConfigException(
        providerId != null
            ? 'Unknown email provider "$providerId"'
            : 'Collection scanner "${collection.scanner}" has no IMAP provider',
      );
    }

    ImapSettings? settings;
    final rawSettings = collection.imapSettings;
    if (rawSettings != null && rawSettings.isNotEmpty) {
      try {
        settings = ImapSettings.fromJsonString(rawSettings);
      } catch (e) {
        throw ImapConfigException('Invalid IMAP settings: $e');
      }
    }

    if (provider.id == 'other') {
      if (settings == null) {
        throw const ImapConfigException(
          'Provider "other" requires IMAP settings (host, port, security)',
        );
      }
      provider = provider.copyWith(
        imapHost: settings.host,
        imapPort: settings.port,
        security: settings.security,
      );
    }

    final host = provider.imapHost;
    if (host == null || host.isEmpty) {
      throw ImapConfigException('Provider "${provider.id}" has no IMAP host');
    }

    final secret = collection.accessToken;
    if (secret == null || secret.isEmpty) {
      throw ImapConfigException(
        'Collection ${collection.id} has no stored credential',
      );
    }

    // OAuth (Outlook) has always used the collection name as the address;
    // password logins (Yahoo) used userId.
    final username =
        provider.authType == EmailAuthType.oauth2
            ? (settings?.username ?? collection.name)
            : (settings?.username ?? collection.userId);
    if (username == null || username.isEmpty) {
      throw ImapConfigException(
        'Collection ${collection.id} has no IMAP username',
      );
    }

    return ImapConnectionConfig(
      provider: provider,
      host: host,
      port: provider.imapPort,
      security: provider.security,
      authType: provider.authType,
      username: username,
      secret: secret,
    );
  }
}
