// This file is deprecated. Use google_auth_service.dart instead.
// Re-exports for backward compatibility during migration.
import 'google_auth_service.dart';

export 'google_auth_service.dart'
    show
        GoogleAuthService,
        TokenRefreshResult,
        GoogleAuthException,
        AuthenticatedHttpClient;

// Legacy type aliases for callers that haven't been updated yet.
typedef GoogleDriveAuthService = GoogleAuthService;
typedef GoogleDriveAuthException = GoogleAuthException;
