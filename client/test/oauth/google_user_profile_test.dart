import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:mydatastudio/oauth/login_providers.dart';

class MockHttpClient extends Mock implements http.Client {}

void main() {
  late MockHttpClient mockClient;

  setUp(() {
    mockClient = MockHttpClient();
    registerFallbackValue(Uri.parse('http://localhost'));
  });

  group('LoginProviderExtension.fetchGoogleProfile', () {
    test('successfully fetches profile from People API when status code is 200', () async {
      const mockPeopleJson = '''
      {
        "resourceName": "people/1234567890",
        "emailAddresses": [
          {
            "value": "user@example.com",
            "metadata": {"primary": true}
          }
        ]
      }
      ''';

      when(() => mockClient.get(
            Uri.parse("https://people.googleapis.com/v1/people/me?personFields=emailAddresses"),
            headers: any(named: 'headers'),
          )).thenAnswer((_) async => http.Response(mockPeopleJson, 200));

      final profile = await LoginProviderExtension.fetchGoogleProfile(
        'mock_token',
        client: mockClient,
      );

      expect(profile, isNotNull);
      expect(profile!.userId, equals('1234567890'));
      expect(profile.email, equals('user@example.com'));
      verifyNever(() => mockClient.get(
            Uri.parse("https://www.googleapis.com/oauth2/v2/userinfo"),
            headers: any(named: 'headers'),
          ));
    });

    test('falls back to UserInfo API when People API returns 403 Forbidden', () async {
      const mockUserInfoJson = '''
      {
        "id": "9876543210",
        "email": "fallback@example.com"
      }
      ''';

      when(() => mockClient.get(
            Uri.parse("https://people.googleapis.com/v1/people/me?personFields=emailAddresses"),
            headers: any(named: 'headers'),
          )).thenAnswer((_) async => http.Response('{"error": "Forbidden"}', 403));

      when(() => mockClient.get(
            Uri.parse("https://www.googleapis.com/oauth2/v2/userinfo"),
            headers: any(named: 'headers'),
          )).thenAnswer((_) async => http.Response(mockUserInfoJson, 200));

      final profile = await LoginProviderExtension.fetchGoogleProfile(
        'mock_token',
        client: mockClient,
      );

      expect(profile, isNotNull);
      expect(profile!.userId, equals('9876543210'));
      expect(profile.email, equals('fallback@example.com'));
    });

    test('returns null if both People API and UserInfo API fail', () async {
      when(() => mockClient.get(
            Uri.parse("https://people.googleapis.com/v1/people/me?personFields=emailAddresses"),
            headers: any(named: 'headers'),
          )).thenAnswer((_) async => http.Response('Forbidden', 403));

      when(() => mockClient.get(
            Uri.parse("https://www.googleapis.com/oauth2/v2/userinfo"),
            headers: any(named: 'headers'),
          )).thenAnswer((_) async => http.Response('Unauthorized', 401));

      final profile = await LoginProviderExtension.fetchGoogleProfile(
        'mock_token',
        client: mockClient,
      );

      expect(profile, isNull);
    });
  });
}
