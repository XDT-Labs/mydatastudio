import 'package:mydatatools/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Collection _makeCollection({
  String? accessToken,
  String? refreshToken,
  DateTime? expiration,
}) =>
    Collection(
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
  group('GoogleDriveAuthService', () {
    group('getValidAccessToken', () {
      test('throws GoogleDriveAuthException when no access token stored', () async {
        final collection = _makeCollection(accessToken: null);

        expect(
          () => GoogleDriveAuthService.getValidAccessToken(collection),
          throwsA(isA<GoogleDriveAuthException>()),
        );
      });

      test('throws GoogleDriveAuthException when token expired and no refresh token', () async {
        final collection = _makeCollection(
          accessToken: 'expired-token',
          refreshToken: null,
          // expired 1 hour ago
          expiration: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        );

        expect(
          () => GoogleDriveAuthService.getValidAccessToken(collection),
          throwsA(isA<GoogleDriveAuthException>()),
        );
      });

      test(
        'returns stored token immediately when not near expiry',
        () async {
          // Token valid for another hour — no network call should be made
          final collection = _makeCollection(
            accessToken: 'still-valid-token',
            refreshToken: 'refresh-tok',
            expiration: DateTime.now().toUtc().add(const Duration(hours: 1)),
          );

          // This should NOT throw and should NOT try to hit the network
          // because the token is still valid.
          final token = await GoogleDriveAuthService.getValidAccessToken(
            collection,
          );
          expect(token, equals('still-valid-token'));
        },
      );
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

    group('GoogleDriveAuthException', () {
      test('toString includes message', () {
        const e = GoogleDriveAuthException('user revoked access');
        expect(e.toString(), contains('user revoked access'));
      });

      test('is an Exception', () {
        const e = GoogleDriveAuthException('test');
        expect(e, isA<Exception>());
      });
    });
  });
}
