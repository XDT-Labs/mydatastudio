import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/folder_role_mapper.dart';

class EmailProviderRegistry {
  EmailProviderRegistry._();

  static const gmail = EmailProvider(
    id: 'gmail',
    displayName: 'Gmail',
    imapHost: 'imap.gmail.com',
    authType: EmailAuthType.oauth2,
    oauthService: 'google',
    domains: ['gmail.com', 'googlemail.com'],
    folderNameHints: {
      '[gmail]/sent mail': FolderRole.sent,
      '[gmail]/trash': FolderRole.trash,
      '[gmail]/spam': FolderRole.junk,
      '[gmail]/drafts': FolderRole.drafts,
      '[gmail]/all mail': FolderRole.all,
      '[gmail]/important': FolderRole.important,
      '[gmail]/starred': FolderRole.flagged,
    },
  );

  static const yahoo = EmailProvider(
    id: 'yahoo',
    displayName: 'Yahoo Mail',
    imapHost: 'imap.mail.yahoo.com',
    authType: EmailAuthType.appPassword,
    oauthService: 'yahoo_app_password',
    domains: ['yahoo.com', 'ymail.com', 'rocketmail.com'],
    folderNameHints: {'bulk mail': FolderRole.junk, 'bulk': FolderRole.junk},
  );

  static const outlook = EmailProvider(
    id: 'outlook',
    displayName: 'Outlook',
    imapHost: 'imap-mail.outlook.com',
    authType: EmailAuthType.oauth2,
    oauthService: 'outlook',
    domains: ['outlook.com', 'hotmail.com', 'live.com', 'msn.com'],
    folderNameHints: {
      'junk email': FolderRole.junk,
      'deleted items': FolderRole.trash,
      'sent items': FolderRole.sent,
    },
  );

  static const icloud = EmailProvider(
    id: 'icloud',
    displayName: 'iCloud Mail',
    imapHost: 'imap.mail.me.com',
    authType: EmailAuthType.appPassword,
    domains: ['icloud.com', 'me.com', 'mac.com'],
    folderNameHints: {
      'deleted messages': FolderRole.trash,
      'sent messages': FolderRole.sent,
    },
  );

  static const aol = EmailProvider(
    id: 'aol',
    displayName: 'AOL Mail',
    imapHost: 'imap.aol.com',
    authType: EmailAuthType.appPassword,
    domains: ['aol.com'],
    folderNameHints: {'bulk mail': FolderRole.junk},
  );

  static const fastmail = EmailProvider(
    id: 'fastmail',
    displayName: 'Fastmail',
    imapHost: 'imap.fastmail.com',
    authType: EmailAuthType.appPassword,
    domains: ['fastmail.com', 'fastmail.fm'],
  );

  /// No host: filled from user-entered settings via
  /// [EmailProvider.copyWith] or [EmailProvider.custom].
  static const other = EmailProvider(
    id: 'other',
    displayName: 'Other',
    authType: EmailAuthType.password,
  );

  static const all = <EmailProvider>[
    gmail,
    yahoo,
    outlook,
    icloud,
    aol,
    fastmail,
    other,
  ];

  static EmailProvider? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Matches the address's domain, or a parent domain of it
  /// (`user@mail.yahoo.com` -> Yahoo). Anything unknown is [other].
  static EmailProvider detectFromEmail(String email) {
    final at = email.lastIndexOf('@');
    if (at < 0) return other;
    var domain = email.substring(at + 1).trim().toLowerCase();
    while (domain.contains('.')) {
      for (final p in all) {
        if (p.domains.contains(domain)) return p;
      }
      domain = domain.substring(domain.indexOf('.') + 1);
    }
    return other;
  }

  /// Maps a legacy IMAP `Collection.scanner` value to its provider; null for
  /// anything else (Gmail uses its API scanner, not IMAP).
  static EmailProvider? forLegacyScanner(String scanner) {
    switch (scanner) {
      case AppConstants.scannerEmailYahoo:
        return yahoo;
      case AppConstants.scannerEmailOutlook:
        return outlook;
    }
    return null;
  }
}
