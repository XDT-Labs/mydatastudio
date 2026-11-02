import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_connection_config.dart';

Collection _c({
  String scanner = 'email.imap',
  String? providerId,
  String? settings,
  String? token = 'secret',
  String? userId,
  String name = 'me@x.org',
}) => Collection(
  id: 'c1',
  name: name,
  path: name,
  type: 'email',
  scanner: scanner,
  scanStatus: 'idle',
  needsReAuth: false,
  emailProviderId: providerId,
  imapSettings: settings,
  accessToken: token,
  userId: userId,
);

void main() {
  test(
    'new collection resolves provider by emailProviderId (app password)',
    () {
      final cfg = ImapConnectionConfig.fromCollection(
        _c(providerId: 'icloud', userId: 'me@icloud.com'),
      );
      expect(cfg.host, 'imap.mail.me.com');
      expect(cfg.port, 993);
      expect(cfg.security, ImapSecurity.ssl);
      expect(cfg.authType, EmailAuthType.appPassword);
      expect(cfg.username, 'me@icloud.com');
      expect(cfg.secret, 'secret');
    },
  );

  test('legacy email.yahoo resolves to Yahoo and logs in as userId', () {
    final cfg = ImapConnectionConfig.fromCollection(
      _c(scanner: 'email.yahoo', userId: 'me@yahoo.com', name: 'Display'),
    );
    expect(cfg.provider.id, 'yahoo');
    expect(cfg.host, 'imap.mail.yahoo.com');
    expect(cfg.authType, EmailAuthType.appPassword);
    expect(cfg.username, 'me@yahoo.com');
  });

  test('legacy email.outlook uses OAuth2 and the collection name', () {
    final cfg = ImapConnectionConfig.fromCollection(
      _c(scanner: 'email.outlook', name: 'me@outlook.com', userId: 'ignored'),
    );
    expect(cfg.provider.id, 'outlook');
    expect(cfg.host, 'imap-mail.outlook.com');
    expect(cfg.authType, EmailAuthType.oauth2);
    expect(cfg.username, 'me@outlook.com');
  });

  test('other takes host/port/security/username from ImapSettings', () {
    final cfg = ImapConnectionConfig.fromCollection(
      _c(
        providerId: 'other',
        settings:
            const ImapSettings(
              host: '127.0.0.1',
              port: 3143,
              security: ImapSecurity.none,
              username: 'alice@test.local',
            ).toJsonString(),
        userId: 'ignored',
      ),
    );
    expect(cfg.host, '127.0.0.1');
    expect(cfg.port, 3143);
    expect(cfg.security, ImapSecurity.none);
    expect(cfg.authType, EmailAuthType.password);
    expect(cfg.username, 'alice@test.local');
  });

  group('unresolvable collections fail loudly', () {
    void rejects(String why, Collection c) => test(why, () {
      expect(
        () => ImapConnectionConfig.fromCollection(c),
        throwsA(isA<ImapConfigException>()),
      );
    });

    rejects('unknown provider id', _c(providerId: 'nope'));
    rejects('non-IMAP legacy scanner', _c(scanner: 'email.gmail'));
    rejects('imap scanner without a provider id', _c());
    rejects('other without settings', _c(providerId: 'other'));
    rejects(
      'other with malformed settings',
      _c(providerId: 'other', settings: '{not json'),
    );
    rejects(
      'missing credential',
      _c(scanner: 'email.yahoo', userId: 'u', token: null),
    );
    rejects('missing username', _c(scanner: 'email.yahoo'));
  });
}
