import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mydatastudio/oauth/microsoft_auth.dart';

void main() {
  group('classifyMicrosoftAuthError', () {
    test('admin consent codes are recognised wherever they appear', () {
      for (final raw in [
        'AADSTS65001: The user or administrator has not consented to use the application',
        'AADSTS90094: The grant requires admin permission.',
        'authorization error [consent_required: AADSTS65001 ...]',
        'access_denied: AADSTS90094: admin consent required',
        'Need admin approval. contoso.com needs permission to access resources',
        'error=interaction_required&error_description=AADSTS90094',
      ]) {
        expect(
          classifyMicrosoftAuthError(raw),
          MicrosoftAuthProblem.adminConsentRequired,
          reason: raw,
        );
      }
    });

    test('a bare interaction_required is not blamed on the admin without a '
        'known code', () {
      expect(
        classifyMicrosoftAuthError('error: interaction_required'),
        MicrosoftAuthProblem.unknown,
      );
    });

    test('IMAP AUTHENTICATE failure means IMAP is disabled or blocked', () {
      expect(
        classifyMicrosoftAuthError(
          'ImapException: AUTHENTICATE failed. a2 NO AUTHENTICATE failed.',
        ),
        MicrosoftAuthProblem.imapDisabled,
      );
    });

    test('invalid_grant means the sign-in has to be repeated', () {
      expect(
        classifyMicrosoftAuthError(
          'invalid_grant: AADSTS70008: The provided authorization code or '
          'refresh token has expired',
        ),
        MicrosoftAuthProblem.reauthRequired,
      );
    });

    test('anything else is unknown and has no canned message', () {
      expect(
        classifyMicrosoftAuthError('SocketException: connection refused'),
        MicrosoftAuthProblem.unknown,
      );
      expect(MicrosoftAuthProblem.unknown.message, isNull);
    });

    test('messages are plain language an IT admin can act on', () {
      final consent = MicrosoftAuthProblem.adminConsentRequired.message!;
      expect(consent, contains('administrator'));
      expect(consent, contains('IMAP.AccessAsUser.All'));
      final imap = MicrosoftAuthProblem.imapDisabled.message!;
      expect(imap, contains('IMAP'));
      expect(imap, contains('Set-CASMailbox'));
    });
  });

  group('refreshMicrosoftTokens', () {
    late List<http.Request> requests;

    http.Client server(int status, Map<String, dynamic> body) =>
        MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(body),
            status,
            headers: {'content-type': 'application/json'},
          );
        });

    setUp(() => requests = []);

    test('public client: sends client_id and no client_secret', () async {
      final result = await refreshMicrosoftTokens(
        refreshToken: 'old-rt',
        clientId: 'cid',
        httpClient: server(200, {
          'access_token': 'new-at',
          'refresh_token': 'new-rt',
          'expires_in': 3600,
        }),
      );

      final body = requests.single.bodyFields;
      expect(requests.single.url.path, '/common/oauth2/v2.0/token');
      expect(body['grant_type'], 'refresh_token');
      expect(body['client_id'], 'cid');
      expect(body['refresh_token'], 'old-rt');
      expect(body.containsKey('client_secret'), isFalse);
      expect(body['scope'], contains('IMAP.AccessAsUser.All'));
      expect(result.accessToken, 'new-at');
      // Microsoft rotates refresh tokens; the caller must store the new one.
      expect(result.refreshToken, 'new-rt');
    });

    test('keeps the old refresh token when none is returned', () async {
      final result = await refreshMicrosoftTokens(
        refreshToken: 'old-rt',
        clientId: 'cid',
        httpClient: server(200, {'access_token': 'at', 'expires_in': 60}),
      );
      expect(result.refreshToken, 'old-rt');
    });

    test('invalid_grant is reported so the collection can be flagged '
        'needs_re_auth', () async {
      await expectLater(
        refreshMicrosoftTokens(
          refreshToken: 'dead',
          clientId: 'cid',
          httpClient: server(400, {
            'error': 'invalid_grant',
            'error_description': 'AADSTS70008: expired',
          }),
        ),
        throwsA(
          isA<MicrosoftAuthException>().having(
            (e) => e.isInvalidGrant,
            'isInvalidGrant',
            isTrue,
          ),
        ),
      );
    });

    test('other failures are not treated as a dead grant', () async {
      await expectLater(
        refreshMicrosoftTokens(
          refreshToken: 'rt',
          clientId: 'cid',
          httpClient: server(500, {'error': 'temporarily_unavailable'}),
        ),
        throwsA(
          isA<MicrosoftAuthException>().having(
            (e) => e.isInvalidGrant,
            'isInvalidGrant',
            isFalse,
          ),
        ),
      );
    });
  });
}
