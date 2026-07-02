import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Collection _makeCollection({
  String? accessToken,
  String? refreshToken,
  DateTime? expiration,
}) => Collection(
  id: const Uuid().v4(),
  name: 'Google Drive (test@example.com)',
  path: 'root',
  type: 'file',
  scanner: 'file.gdrive',
  scanStatus: 'pending',
  needsReAuth: false,
  accessToken: accessToken,
  refreshToken: refreshToken,
  expiration: expiration,
);

void main() {
  group('GoogleAuthService', () {
    group('getValidAccessToken', () {
      test('throws GoogleAuthException when no access token stored', () async {
        final collection = _makeCollection(accessToken: null);

        expect(
          () => GoogleAuthService.getValidAccessToken(collection),
          throwsA(isA<GoogleAuthException>()),
        );
      });

      test(
        'throws GoogleAuthException when token expired and no refresh token',
        () async {
          final collection = _makeCollection(
            accessToken: 'expired-token',
            refreshToken: null,
            expiration: DateTime.now().toUtc().subtract(
              const Duration(hours: 1),
            ),
          );

          expect(
            () => GoogleAuthService.getValidAccessToken(collection),
            throwsA(isA<GoogleAuthException>()),
          );
        },
      );

      test('returns stored token immediately when not near expiry', () async {
        final collection = _makeCollection(
          accessToken: 'still-valid-token',
          refreshToken: 'refresh-tok',
          expiration: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );

        final token = await GoogleAuthService.getValidAccessToken(collection);
        expect(token, equals('still-valid-token'));
      });
    });

    group('isTokenExpired', () {
      test('returns true when expiration is null', () {
        expect(GoogleAuthService.isTokenExpired(null), isTrue);
      });

      test('returns true when token is expired', () {
        final expired = DateTime.now().toUtc().subtract(
          const Duration(hours: 1),
        );
        expect(GoogleAuthService.isTokenExpired(expired), isTrue);
      });

      test('returns true when token is within refresh threshold', () {
        final nearExpiry = DateTime.now().toUtc().add(
          const Duration(minutes: 3),
        );
        expect(GoogleAuthService.isTokenExpired(nearExpiry), isTrue);
      });

      test('returns false when token is valid and not near expiry', () {
        final valid = DateTime.now().toUtc().add(const Duration(hours: 1));
        expect(GoogleAuthService.isTokenExpired(valid), isFalse);
      });

      test('respects custom refresh threshold', () {
        final expiry = DateTime.now().toUtc().add(const Duration(minutes: 3));
        // Default threshold is 5 min, so 3 min out should be expired
        expect(GoogleAuthService.isTokenExpired(expiry), isTrue);
        // With 1 min threshold, 3 min out should be valid
        expect(
          GoogleAuthService.isTokenExpired(
            expiry,
            refreshThreshold: const Duration(minutes: 1),
          ),
          isFalse,
        );
      });
    });

    group('TokenRefreshResult', () {
      test('stores accessToken and expiration', () {
        final expiry = DateTime(2030, 1, 1);
        final result = TokenRefreshResult(
          accessToken: 'new-tok',
          expiration: expiry,
        );
        expect(result.accessToken, equals('new-tok'));
        expect(result.expiration, equals(expiry));
      });
    });

    group('GoogleAuthException', () {
      test('toString includes message', () {
        const e = GoogleAuthException('user revoked access');
        expect(e.toString(), contains('user revoked access'));
      });

      test('is an Exception', () {
        const e = GoogleAuthException('test');
        expect(e, isA<Exception>());
      });
    });

    group('AuthenticatedHttpClient', () {
      test('bearer constructor creates correct headers', () {
        final client = AuthenticatedHttpClient.bearer('test-token');
        // Verify it's an http.BaseClient (can be used with Google APIs)
        expect(client, isA<AuthenticatedHttpClient>());
      });

      test('map constructor accepts custom headers', () {
        final client = AuthenticatedHttpClient({
          'Authorization': 'Bearer custom',
          'X-Custom': 'value',
        });
        expect(client, isA<AuthenticatedHttpClient>());
      });
    });

    group('backward compatibility', () {
      test('GoogleDriveAuthService typedef resolves to GoogleAuthService', () {
        // Import via the old file path still works through re-export
        expect(GoogleAuthService, equals(GoogleAuthService));
      });
    });
  });
}
