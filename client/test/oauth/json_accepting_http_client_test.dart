import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:mydatastudio/oauth/json_accepting_http_client.dart';

class MockHttpClient extends Mock implements http.Client {}

class FakeBaseRequest extends Fake implements http.BaseRequest {}

void main() {
  late MockHttpClient mockInnerClient;
  late JsonAcceptingHttpClient httpClient;
  final testScopes = ['openid', 'email', 'offline_access'];

  setUp(() {
    mockInnerClient = MockHttpClient();
    httpClient = JsonAcceptingHttpClient(
      httpClient: mockInnerClient,
      scopes: testScopes,
    );
    registerFallbackValue(Uri.parse('http://localhost'));
    registerFallbackValue(http.Request('GET', Uri.parse('http://localhost')));
  });

  test('adds Accept: application/json header to all requests', () async {
    final request = http.Request('GET', Uri.parse('http://example.com'));

    when(() => mockInnerClient.send(any())).thenAnswer(
      (_) async => http.StreamedResponse(Stream.fromIterable([]), 200),
    );

    await httpClient.send(request);

    final capturedRequest =
        verify(() => mockInnerClient.send(captureAny())).captured.single
            as http.BaseRequest;
    expect(capturedRequest.headers['Accept'], 'application/json');
  });

  test('injects scope parameter in token request if missing', () async {
    // A typical token request has grant_type
    final request = http.Request('POST', Uri.parse('http://example.com/token'))
      ..bodyFields = {'grant_type': 'authorization_code', 'code': '12345'};

    when(() => mockInnerClient.send(any())).thenAnswer(
      (_) async => http.StreamedResponse(Stream.fromIterable([]), 200),
    );

    await httpClient.send(request);

    final capturedRequest =
        verify(() => mockInnerClient.send(captureAny())).captured.single
            as http.Request;
    expect(capturedRequest.bodyFields['scope'], testScopes.join(' '));
    expect(capturedRequest.bodyFields['grant_type'], 'authorization_code');
    expect(capturedRequest.bodyFields['code'], '12345');
  });

  test('does not inject scope parameter if already present', () async {
    final request = http.Request('POST', Uri.parse('http://example.com/token'))
      ..bodyFields = {
        'grant_type': 'authorization_code',
        'scope': 'existing_scope',
      };

    when(() => mockInnerClient.send(any())).thenAnswer(
      (_) async => http.StreamedResponse(Stream.fromIterable([]), 200),
    );

    await httpClient.send(request);

    final capturedRequest =
        verify(() => mockInnerClient.send(captureAny())).captured.single
            as http.Request;
    expect(capturedRequest.bodyFields['scope'], 'existing_scope');
  });

  test(
    'does not inject scope parameter if not a token request (no grant_type)',
    () async {
      final request = http.Request(
        'POST',
        Uri.parse('http://example.com/other'),
      )..bodyFields = {'foo': 'bar'};

      when(() => mockInnerClient.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(Stream.fromIterable([]), 200),
      );

      await httpClient.send(request);

      final capturedRequest =
          verify(() => mockInnerClient.send(captureAny())).captured.single
              as http.Request;
      expect(capturedRequest.bodyFields.containsKey('scope'), isFalse);
    },
  );
}
