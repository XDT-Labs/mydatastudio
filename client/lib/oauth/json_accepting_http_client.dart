import 'package:http/http.dart' as http;

/// A custom HTTP client that adds the 'Accept: application/json' header to all requests.
/// Additionally, it can inject a 'scope' parameter into POST requests if it is missing,
/// which is required by some OAuth2 providers (like Microsoft Azure AD v2.0) during
/// the token exchange step.
class JsonAcceptingHttpClient extends http.BaseClient {
  final http.Client _httpClient;
  final List<String>? scopes;

  JsonAcceptingHttpClient({http.Client? httpClient, this.scopes})
      : _httpClient = httpClient ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['Accept'] = 'application/json';

    // Microsoft v2.0 token endpoint (and potentially others) requires the 'scope' parameter
    // in the token exchange POST request. The oauth2 package doesn't always include it.
    if (request.method == 'POST' &&
        scopes != null &&
        scopes!.isNotEmpty &&
        request.url.path.endsWith('/token')) {
      
      bool injected = false;
      if (request is http.Request) {
        if (!request.bodyFields.containsKey('scope') && !request.body.contains('scope=')) {
          final body = Map<String, String>.from(request.bodyFields);
          body['scope'] = scopes!.join(' ');
          request.bodyFields = body;
          injected = true;
        }
      }
      
      if (injected) {
        // Use a simple print or dev log for this specific internal check
        // ignore: avoid_print
        print("DEBUG: Injected scopes into token request: ${scopes!.join(' ')}");
      }
    }

    final response = await _httpClient.send(request);
    
    // For debugging authentication failures, we could intercept the response here
    // but StreamedResponse can only be read once. 
    return response;
  }

  @override
  void close() {
    _httpClient.close();
    super.close();
  }
}
