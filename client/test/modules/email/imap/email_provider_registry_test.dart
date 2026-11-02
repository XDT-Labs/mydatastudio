import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';

void main() {
  group('detectFromEmail', () {
    // A wrong match would send a user's password to the wrong host.
    const expected = {
      'a@yahoo.com': 'yahoo',
      'a@ymail.com': 'yahoo',
      'a@rocketmail.com': 'yahoo',
      'a@outlook.com': 'outlook',
      'a@hotmail.com': 'outlook',
      'a@live.com': 'outlook',
      'a@msn.com': 'outlook',
      'a@icloud.com': 'icloud',
      'a@me.com': 'icloud',
      'a@mac.com': 'icloud',
      'a@gmail.com': 'gmail',
      'a@googlemail.com': 'gmail',
      'a@aol.com': 'aol',
      'a@fastmail.com': 'fastmail',
      'a@yahoo.co.uk': 'yahoo',
      'a@yahoo.ca': 'yahoo',
      'a@yahoo.com.au': 'yahoo',
      'a@yahoo.co.jp': 'yahoo',
      'a@yahoo.fr': 'yahoo',
      'a@yahoo.de': 'yahoo',
      'a@att.net': 'att',
      'a@sbcglobal.net': 'att',
      'a@bellsouth.net': 'att',
      'a@verizon.net': 'aol',
      'a@aim.com': 'aol',
      'a@ya.ru': 'yandex',
      'a@yandex.com': 'yandex',
      'a@gmx.de': 'gmx_de',
      'a@gmx.net': 'gmx_de',
      'a@gmx.com': 'gmx_com',
      'a@gmx.co.uk': 'gmx_com',
      'a@web.de': 'webde',
      'a@mail.com': 'mailcom',
      'a@usa.com': 'mailcom',
      'a@email.com': 'mailcom',
      'a@zohomail.eu': 'zoho',
      'a@zoho.com': 'zoho',
      'a@hotmail.co.uk': 'outlook',
      'a@passport.com': 'outlook',
    };
    expected.forEach((email, id) {
      test('$email -> $id', () {
        expect(EmailProviderRegistry.detectFromEmail(email).id, id);
      });
    });

    test('is case-insensitive and trims', () {
      expect(
        EmailProviderRegistry.detectFromEmail('  Bob@GMail.COM ').id,
        'gmail',
      );
    });

    test('subdomain of a known domain maps to it', () {
      expect(
        EmailProviderRegistry.detectFromEmail('a@mail.yahoo.com').id,
        'yahoo',
      );
    });

    test('lookalike domain does not match', () {
      expect(
        EmailProviderRegistry.detectFromEmail('a@notyahoo.com').id,
        'other',
      );
      expect(
        EmailProviderRegistry.detectFromEmail('a@yahoo.com.evil.io').id,
        'other',
      );
    });

    test('unknown or malformed -> other', () {
      expect(
        EmailProviderRegistry.detectFromEmail('a@example.org').id,
        'other',
      );
      expect(EmailProviderRegistry.detectFromEmail('nonsense').id, 'other');
      expect(EmailProviderRegistry.detectFromEmail('').id, 'other');
    });
  });

  group('registry', () {
    test('byId finds every provider; unknown is null', () {
      for (final p in EmailProviderRegistry.all) {
        expect(EmailProviderRegistry.byId(p.id), same(p));
      }
      expect(EmailProviderRegistry.byId('nope'), isNull);
    });

    test('every non-other provider has an SSL host on 993', () {
      for (final p in EmailProviderRegistry.all.where((p) => p.id != 'other')) {
        expect(p.imapHost, isNotNull, reason: p.id);
        expect(p.imapPort, 993, reason: p.id);
        expect(p.security, ImapSecurity.ssl, reason: p.id);
      }
      expect(EmailProviderRegistry.other.imapHost, isNull);
    });

    test('every provider except other has setup steps', () {
      for (final p in EmailProviderRegistry.all.where((p) => p.id != 'other')) {
        expect(p.setupSteps, isNotEmpty, reason: p.id);
      }
    });

    test('provider quirks have plain-language auth failure hints', () {
      String hint(String id) =>
          EmailProviderRegistry.byId(id)!.authFailureHint ?? '';
      expect(hint('icloud'), contains('revokes'));
      expect(hint('gmx_de'), contains('POP3 & IMAP'));
      expect(hint('webde'), contains('POP3 & IMAP'));
      expect(hint('mailcom'), contains('POP3 & IMAP'));
      expect(hint('zoho'), contains('export'));
      expect(hint('yandex'), contains('few hours'));
      expect(hint('att'), contains('secure mail key'));
    });

    test('AT&T uses its own host and AOL treats Bulk as junk', () {
      expect(EmailProviderRegistry.att.imapHost, 'imap.mail.att.net');
      expect(EmailProviderRegistry.aol.folderNameHints['bulk'], isNotNull);
    });

    test('new providers use the hosts from their plans', () {
      const hosts = {
        'yandex': 'imap.yandex.com',
        'gmx_com': 'imap.gmx.com',
        'gmx_de': 'imap.gmx.net',
        'mailcom': 'imap.mail.com',
        'webde': 'imap.web.de',
        'zoho': 'imap.zoho.com',
      };
      hosts.forEach((id, host) {
        expect(EmailProviderRegistry.byId(id)!.imapHost, host, reason: id);
      });
    });

    test('only Zoho has regions, and its default is the first one', () {
      for (final p in EmailProviderRegistry.all) {
        expect(p.regionHosts.isNotEmpty, p.id == 'zoho', reason: p.id);
      }
      final zoho = EmailProviderRegistry.zoho;
      expect(zoho.regionHosts.values.first, zoho.imapHost);
      expect(zoho.regionHosts['Europe'], 'imap.zoho.eu');
    });

    test('legacy scanners resolve to their providers', () {
      final yahoo =
          EmailProviderRegistry.forLegacyScanner(
            AppConstants.scannerEmailYahoo,
          )!;
      final outlook =
          EmailProviderRegistry.forLegacyScanner(
            AppConstants.scannerEmailOutlook,
          )!;
      expect(yahoo.imapHost, 'imap.mail.yahoo.com');
      expect(outlook.imapHost, 'outlook.office365.com');
      expect(
        EmailProviderRegistry.forLegacyScanner(AppConstants.scannerFileLocal),
        isNull,
      );
    });

    test('other can be made concrete', () {
      final p = EmailProviderRegistry.other.copyWith(
        imapHost: 'mail.example.org',
        security: ImapSecurity.startTls,
        imapPort: 143,
      );
      expect(p.id, 'other');
      expect(p.imapHost, 'mail.example.org');
      expect(p.imapPort, 143);
      const c = EmailProvider.custom(host: 'h');
      expect(c.imapHost, 'h');
    });

    test('ImapSettings JSON round-trips and carries no password', () {
      const s = ImapSettings(
        host: 'h',
        port: 143,
        security: ImapSecurity.startTls,
        username: 'u',
      );
      final json = s.toJsonString();
      expect(json.toLowerCase(), isNot(contains('pass')));
      final back = ImapSettings.fromJsonString(json);
      expect(back.host, 'h');
      expect(back.port, 143);
      expect(back.security, ImapSecurity.startTls);
      expect(back.username, 'u');
    });
  });
}
