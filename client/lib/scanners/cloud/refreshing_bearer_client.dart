import 'package:http/http.dart' as http;
import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart'
    show TokenRefreshResult;

/// Bearer-token client that refreshes the token before each request once it
/// is within 5 minutes of expiry. Concurrent requests share one refresh.
class RefreshingBearerClient extends http.BaseClient {
  RefreshingBearerClient({
    required String token,
    required DateTime? expiry,
    required this.refresh,
    http.Client? inner,
    DateTime Function()? now,
  }) : _token = token,
       _expiry = expiry,
       _inner = inner ?? http.Client(),
       _now = now ?? (() => DateTime.now().toUtc());

  final Future<TokenRefreshResult> Function() refresh;
  final http.Client _inner;
  final DateTime Function() _now;
  String _token;
  DateTime? _expiry;
  Future<void>? _refreshing;

  static bool isNearExpiry(DateTime? expiry, DateTime now) =>
      expiry == null ||
      now.isAfter(expiry.subtract(const Duration(minutes: 5)));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (isNearExpiry(_expiry, _now())) {
      await (_refreshing ??= _refreshToken().whenComplete(
        () => _refreshing = null,
      ));
    }
    request.headers['Authorization'] = 'Bearer $_token';
    return _inner.send(request);
  }

  Future<void> _refreshToken() async {
    final result = await refresh();
    _token = result.accessToken;
    _expiry = result.expiration.toUtc();
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
