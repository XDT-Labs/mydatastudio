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
    setupSteps: [
      'Open myaccount.google.com > Security.',
      'Turn on 2-Step Verification if it is off.',
      'Search for "App passwords", create one named "My Data Studio", and '
          'paste the 16-character password here.',
      'If App passwords is missing, your Workspace admin has turned it off. '
          'Use Google Takeout and import the file instead.',
    ],
  );

  static const yahoo = EmailProvider(
    id: 'yahoo',
    displayName: 'Yahoo Mail',
    imapHost: 'imap.mail.yahoo.com',
    authType: EmailAuthType.appPassword,
    oauthService: 'yahoo_app_password',
    domains: [
      'yahoo.com',
      'ymail.com',
      'rocketmail.com',
      'yahoo.co.uk',
      'yahoo.ca',
      'yahoo.com.au',
      'yahoo.fr',
      'yahoo.de',
      'yahoo.it',
      'yahoo.es',
      'yahoo.ie',
      'yahoo.se',
      'yahoo.gr',
      'yahoo.in',
      'yahoo.co.in',
      'yahoo.co.jp',
      'yahoo.co.nz',
      'yahoo.co.id',
      'yahoo.com.br',
      'yahoo.com.mx',
      'yahoo.com.ar',
      'yahoo.com.sg',
      'yahoo.com.hk',
      'yahoo.com.tw',
      'yahoo.com.ph',
    ],
    folderNameHints: {'bulk mail': FolderRole.junk, 'bulk': FolderRole.junk},
    setupSteps: [
      'Open login.yahoo.com/account/security.',
      'Click "Generate app password" (older layout: "Manage app passwords").',
      'Name it "My Data Studio", click Generate, and paste the password here.',
    ],
  );

  /// Yahoo-hosted ISP mail: Yahoo's back end, but its own host and a "secure
  /// mail key" in place of an app password.
  static const att = EmailProvider(
    id: 'att',
    displayName: 'AT&T Mail',
    imapHost: 'imap.mail.att.net',
    authType: EmailAuthType.appPassword,
    domains: [
      'att.net',
      'sbcglobal.net',
      'bellsouth.net',
      'pacbell.net',
      'flash.net',
      'swbell.net',
      'wans.net',
      'prodigy.net',
      'ameritech.net',
      'nvbell.net',
      'snet.net',
    ],
    folderNameHints: {'bulk mail': FolderRole.junk, 'bulk': FolderRole.junk},
    setupSteps: [
      'Sign in to your AT&T profile (att.com > My Account > Profile).',
      'Open "Sign-in info" and choose "Manage secure mail key".',
      'Create a secure mail key for "My Data Studio" and paste it here in '
          'place of your password.',
    ],
    authFailureHint:
        'AT&T Mail does not accept your normal password for other apps. Use a '
        'secure mail key created on your AT&T profile page.',
  );

  static const outlook = EmailProvider(
    id: 'outlook',
    displayName: 'Outlook',
    imapHost: 'outlook.office365.com',
    authType: EmailAuthType.oauth2,
    oauthService: 'outlook',
    domains: [
      'outlook.com',
      'hotmail.com',
      'live.com',
      'msn.com',
      'hotmail.co.uk',
      'passport.com',
    ],
    folderNameHints: {
      'junk email': FolderRole.junk,
      'deleted items': FolderRole.trash,
      'sent items': FolderRole.sent,
    },
    setupSteps: [
      'Choose "Continue with Outlook".',
      'Sign in with your Microsoft account and approve read access to mail.',
    ],
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
    setupSteps: [
      'Open account.apple.com > Sign-In and Security > App-Specific '
          'Passwords.',
      'Click +, name it "My Data Studio", confirm with your Apple Account '
          'password, and paste the generated password here.',
    ],
    authFailureHint:
        'Changing or resetting your Apple Account password revokes every '
        'app-specific password. Create a new app-specific password and use it '
        'here.',
  );

  static const aol = EmailProvider(
    id: 'aol',
    displayName: 'AOL Mail',
    imapHost: 'imap.aol.com',
    authType: EmailAuthType.appPassword,
    domains: [
      'aol.com',
      'aim.com',
      'love.com',
      'games.com',
      'wow.com',
      'verizon.net',
    ],
    folderNameHints: {'bulk mail': FolderRole.junk, 'bulk': FolderRole.junk},
    setupSteps: [
      'Sign in at login.aol.com > Account Security.',
      'Click "Generate app password" (at the bottom). Choose "Other app" and '
          'name it "My Data Studio".',
      'Click Generate and paste the password here.',
    ],
  );

  static const fastmail = EmailProvider(
    id: 'fastmail',
    displayName: 'Fastmail',
    imapHost: 'imap.fastmail.com',
    authType: EmailAuthType.appPassword,
    domains: [
      'fastmail.com',
      'fastmail.fm',
      'fastmail.us',
      'fastmail.co.uk',
      'fastmail.net',
      'fastmail.org',
      'messagingengine.com',
    ],
    setupSteps: [
      'In Fastmail, open Settings > Privacy & Security > Manage app '
          'passwords and access.',
      'Create a new app password with IMAP access (read-only if offered), '
          'name it "My Data Studio", and paste it here.',
    ],
  );

  static const yandex = EmailProvider(
    id: 'yandex',
    displayName: 'Yandex Mail',
    imapHost: 'imap.yandex.com',
    authType: EmailAuthType.appPassword,
    domains: [
      'yandex.com',
      'yandex.ru',
      'ya.ru',
      'yandex.by',
      'yandex.kz',
      'yandex.ua',
      'narod.ru',
    ],
    setupSteps: [
      'In Yandex Mail, open Settings > Email clients and turn on both the '
          'IMAP option and "App passwords and OAuth tokens".',
      'Open id.yandex.com > Security > App passwords, create one for Mail, '
          'and paste it here. It is shown only once.',
    ],
    authFailureHint:
        'A new Yandex app password can take a few hours to start working. If '
        'you just created it, wait and try again. Also check that both '
        'options under Settings > Email clients are turned on.',
  );

  // GMX, mail.com and WEB.DE share a company and the same IMAP rules.
  static const _unitedInternetSteps = [
    'In webmail, open Settings > POP3 & IMAP and enable access to this '
        'account via POP3 and IMAP.',
    'If you use two-factor authentication, create an application-specific '
        'password in your security settings.',
    'Enter your account password (or the application-specific password) '
        'here.',
  ];

  static const _unitedInternetHint =
      'IMAP access may have been switched off by the provider, which happens '
      'after a long period without POP3/IMAP use. Turn it on again in '
      'Settings > POP3 & IMAP, then retry. If you use two-factor '
      'authentication, use an application-specific password.';

  static const gmxCom = EmailProvider(
    id: 'gmx_com',
    displayName: 'GMX (International)',
    imapHost: 'imap.gmx.com',
    authType: EmailAuthType.appPassword,
    domains: ['gmx.com', 'gmx.us', 'gmx.co.uk', 'gmx.fr', 'gmx.es'],
    setupSteps: _unitedInternetSteps,
    authFailureHint: _unitedInternetHint,
  );

  static const gmxDe = EmailProvider(
    id: 'gmx_de',
    displayName: 'GMX (DE/AT/CH)',
    imapHost: 'imap.gmx.net',
    authType: EmailAuthType.appPassword,
    domains: ['gmx.de', 'gmx.at', 'gmx.ch', 'gmx.net'],
    setupSteps: _unitedInternetSteps,
    authFailureHint: _unitedInternetHint,
  );

  static const mailCom = EmailProvider(
    id: 'mailcom',
    displayName: 'mail.com',
    imapHost: 'imap.mail.com',
    authType: EmailAuthType.appPassword,
    domains: [
      'mail.com',
      'email.com',
      'usa.com',
      'myself.com',
      'consultant.com',
      'post.com',
      'europe.com',
      'asia.com',
      'techie.com',
      'engineer.com',
      'writeme.com',
      'cheerful.com',
    ],
    setupSteps: [
      ..._unitedInternetSteps,
      'Note: IMAP may require a paid (Premium) mail.com plan.',
    ],
    authFailureHint:
        '$_unitedInternetHint mail.com may also limit IMAP to paid plans.',
  );

  static const webDe = EmailProvider(
    id: 'webde',
    displayName: 'WEB.DE',
    imapHost: 'imap.web.de',
    authType: EmailAuthType.appPassword,
    domains: ['web.de'],
    setupSteps: _unitedInternetSteps,
    authFailureHint: _unitedInternetHint,
  );

  static const zoho = EmailProvider(
    id: 'zoho',
    displayName: 'Zoho Mail',
    imapHost: 'imap.zoho.com',
    authType: EmailAuthType.appPassword,
    domains: [
      'zoho.com',
      'zohomail.com',
      'zoho.eu',
      'zohomail.eu',
      'zohomail.in',
      'zohomail.com.au',
      'zohomail.jp',
      'zohomail.ca',
    ],
    regionHosts: {
      'United States': 'imap.zoho.com',
      'Europe': 'imap.zoho.eu',
      'India': 'imap.zoho.in',
      'Australia': 'imap.zoho.com.au',
      'Japan': 'imap.zoho.jp',
      'Canada': 'imap.zohocloud.ca',
    },
    setupSteps: [
      'In Zoho Mail, open Settings > Mail Accounts > IMAP and turn on IMAP '
          'Access.',
      'If you use two-factor authentication: accounts.zoho.com > Security > '
          'App Passwords > Generate New Password.',
      'Choose your region (where your account is hosted) and paste the '
          'password here.',
    ],
    authFailureHint:
        'Check that IMAP Access is turned on in Zoho Mail settings and that '
        'the region matches where your account is hosted. Free Zoho plans '
        'may not include IMAP; in that case export your mailbox from '
        'Settings > Import/Export and import the file instead.',
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
    att,
    outlook,
    icloud,
    aol,
    fastmail,
    yandex,
    gmxCom,
    gmxDe,
    mailCom,
    webDe,
    zoho,
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
