import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_connection_config.dart';
import 'package:mydatastudio/modules/email/services/imap/outlook_token_refresher.dart';
import 'package:mydatastudio/oauth/microsoft_auth.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  Collection collection({DateTime? expiration, String? refreshToken = 'rt-1'}) =>
      Collection(
        id: 'c1',
        name: 'me@outlook.com',
        path: 'me@outlook.com',
        type: 'email',
        scanner: 'email.imap',
        scanStatus: 'idle',
        needsReAuth: false,
        emailProviderId: 'outlook',
        accessToken: 'old-at',
        refreshToken: refreshToken,
        expiration: expiration,
      );

  ImapConnectionConfig configFor(Collection c) =>
      ImapConnectionConfig.fromCollection(c);

  MicrosoftTokenRefresh fresh() => MicrosoftTokenRefresh(
    accessToken: 'new-at',
    refreshToken: 'rt-2',
    expiration: now.add(const Duration(hours: 1)),
  );

  // The bug: Outlook sync died an hour after sign-in because nothing renewed
  // the access token.
  group('ensureFreshOutlookToken', () {
    test('expired token is refreshed, persisted, and used for the login',
        () async {
      final c = collection(expiration: now.subtract(const Duration(minutes: 1)));
      MicrosoftTokenRefresh? saved;
      String? usedRefresh, usedClient;
      final config = await ensureFreshOutlookToken(
        collection: c,
        config: configFor(c),
        clientId: () async => 'client-x',
        persist: (t) async => saved = t,
        now: now,
        refresh: ({required refreshToken, required clientId}) async {
          usedRefresh = refreshToken;
          usedClient = clientId;
          return fresh();
        },
      );
      expect(config.secret, 'new-at');
      expect(saved?.refreshToken, 'rt-2'); // rotated token must be stored
      expect(usedRefresh, 'rt-1');
      expect(usedClient, 'client-x');
    });

    test('token inside the margin is refreshed, token far from expiry is not',
        () async {
      var calls = 0;
      Future<MicrosoftTokenRefresh> refresh({
        required String refreshToken,
        required String clientId,
      }) async {
        calls++;
        return fresh();
      }

      for (final minutes in [3, 30]) {
        final c = collection(expiration: now.add(Duration(minutes: minutes)));
        await ensureFreshOutlookToken(
          collection: c,
          config: configFor(c),
          clientId: () async => 'id',
          persist: (_) async {},
          now: now,
          refresh: refresh,
        );
      }
      expect(calls, 1);
    });

    test('unknown expiration always refreshes', () async {
      final c = collection(expiration: null);
      final config = await ensureFreshOutlookToken(
        collection: c,
        config: configFor(c),
        clientId: () async => 'id',
        persist: (_) async {},
        now: now,
        refresh: ({required refreshToken, required clientId}) async => fresh(),
      );
      expect(config.secret, 'new-at');
    });

    test('invalid_grant propagates so the caller can flag re-auth', () async {
      final c = collection(expiration: null);
      var persisted = false;
      await expectLater(
        ensureFreshOutlookToken(
          collection: c,
          config: configFor(c),
          clientId: () async => 'id',
          persist: (_) async => persisted = true,
          refresh: ({required refreshToken, required clientId}) async =>
              throw const MicrosoftAuthException('invalid_grant'),
        ),
        throwsA(
          isA<MicrosoftAuthException>().having(
            (e) => e.isInvalidGrant,
            'isInvalidGrant',
            true,
          ),
        ),
      );
      expect(persisted, isFalse);
    });

    test('a missing refresh token is treated as invalid_grant', () async {
      final c = collection(expiration: null, refreshToken: null);
      await expectLater(
        ensureFreshOutlookToken(
          collection: c,
          config: configFor(c),
          clientId: () async => 'id',
          persist: (_) async {},
        ),
        throwsA(isA<MicrosoftAuthException>()),
      );
    });

    test('password providers pass through untouched', () async {
      final c = Collection(
        id: 'c2',
        name: 'me@yahoo.com',
        path: 'me@yahoo.com',
        type: 'email',
        scanner: 'email.imap',
        scanStatus: 'idle',
        needsReAuth: false,
        emailProviderId: EmailProviderRegistry.yahoo.id,
        accessToken: 'pw',
        userId: 'me@yahoo.com',
      );
      final config = configFor(c);
      final result = await ensureFreshOutlookToken(
        collection: c,
        config: config,
        clientId: () async => throw StateError('must not be called'),
        persist: (_) async {},
      );
      expect(identical(result, config), isTrue);
    });
  });
}
