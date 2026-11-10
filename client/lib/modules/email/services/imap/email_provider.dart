import 'dart:convert';

import 'package:mydatastudio/modules/email/services/imap/folder_role_mapper.dart';

enum ImapSecurity { ssl, startTls, none }

enum EmailAuthType { oauth2, appPassword, password }

/// Immutable description of an IMAP provider.
class EmailProvider {
  final String id;
  final String displayName;
  final String? imapHost;
  final int imapPort;
  final ImapSecurity security;
  final EmailAuthType authType;

  /// Matches `Collection.oauthService` for providers that need it.
  final String? oauthService;

  /// Lower-case email domains that map to this provider.
  final List<String> domains;

  /// Lower-case folder name -> role, used when a server sends no SPECIAL-USE
  /// flag for the folder.
  final Map<String, FolderRole> folderNameHints;

  /// Numbered, plain-text steps shown on the setup card.
  final List<String> setupSteps;

  /// Plain-language text shown when login is refused, for provider quirks
  /// (revoked app passwords, IMAP switched off, ...).
  final String? authFailureHint;

  /// Data-centre label -> IMAP host, for providers whose host depends on the
  /// account's region. The first entry is the default. Empty for most.
  final Map<String, String> regionHosts;

  const EmailProvider({
    required this.id,
    required this.displayName,
    this.imapHost,
    this.imapPort = 993,
    this.security = ImapSecurity.ssl,
    required this.authType,
    this.oauthService,
    this.domains = const [],
    this.folderNameHints = const {},
    this.setupSteps = const [],
    this.authFailureHint,
    this.regionHosts = const {},
  });

  /// A concrete provider built from user-entered settings.
  const EmailProvider.custom({
    required String host,
    int port = 993,
    ImapSecurity security = ImapSecurity.ssl,
    EmailAuthType authType = EmailAuthType.password,
  }) : this(
         id: 'other',
         displayName: 'Other',
         imapHost: host,
         imapPort: port,
         security: security,
         authType: authType,
       );

  EmailProvider copyWith({
    String? imapHost,
    int? imapPort,
    ImapSecurity? security,
    EmailAuthType? authType,
  }) => EmailProvider(
    id: id,
    displayName: displayName,
    imapHost: imapHost ?? this.imapHost,
    imapPort: imapPort ?? this.imapPort,
    security: security ?? this.security,
    authType: authType ?? this.authType,
    oauthService: oauthService,
    domains: domains,
    folderNameHints: folderNameHints,
    setupSteps: setupSteps,
    authFailureHint: authFailureHint,
    regionHosts: regionHosts,
  );
}

/// Connection settings stored as JSON in `collections.imap_settings`: all of
/// them for the `other` provider, only the chosen host for providers with
/// [EmailProvider.regionHosts]. Never contains a password.
class ImapSettings {
  final String host;
  final int port;
  final ImapSecurity security;
  final String username;

  const ImapSettings({
    required this.host,
    this.port = 993,
    this.security = ImapSecurity.ssl,
    required this.username,
  });

  String toJsonString() => jsonEncode({
    'host': host,
    'port': port,
    'security': security.name,
    'username': username,
  });

  factory ImapSettings.fromJsonString(String source) {
    final m = jsonDecode(source) as Map<String, dynamic>;
    return ImapSettings(
      host: m['host'] as String,
      port: m['port'] as int? ?? 993,
      security: ImapSecurity.values.firstWhere(
        (s) => s.name == m['security'],
        orElse: () => ImapSecurity.ssl,
      ),
      username: m['username'] as String,
    );
  }
}
