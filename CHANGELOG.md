# Changelog

## [1.0.2] - 2026-03-27

### Changed
- Added PKCE (code_challenge + code_verifier) to Google OAuth flow for additional security against authorization code interception
- Consolidated two duplicate token refresh implementations (GoogleAuthClient and GoogleDriveAuthService) into a single GoogleAuthService
- Gmail isolate token validation now uses local expiry check instead of HTTP tokeninfo call, reducing latency
- Auth dialog manager extended to handle both Gmail and Google Drive re-authentication
- Switched Google OAuth client type from "Web application" to "Desktop" in Google Cloud Console

### Added
- Database migration v13 to flag existing Google collections for re-authentication on upgrade
- AuthenticatedHttpClient with proper close() to prevent HTTP connection leaks
- Backward-compatible re-export file for GoogleDriveAuthService typedef migration

### Removed
- Legacy GoogleAuthClient class (replaced by AuthenticatedHttpClient)
- Unused google_sign_in dependency

## [1.0.1] - 2026-03-27

### Added
- gstack AI workflow skills: `/ship`, `/qa`, `/review`, `/office-hours`, `/plan-eng-review`, `/plan-design-review`, `/plan-ceo-review`, `/investigate`, `/browse`, `/canary`, `/benchmark`, `/retro`, `/document-release`, `/cso`, `/design-review`, `/design-consultation`, `/codex`, and more
- `CLAUDE.md` project guidance for Claude Code with build commands, architecture overview, and gstack skill reference

## [1.0.0] - Initial Release

- Local-first personal data archive and management tool
- Flutter macOS desktop client with SQLite + sqlite_vector for semantic search
- Embedded Python FastAPI service for local LLM inference (no cloud API calls)
- File, email, photo, and cloud drive collection scanning and indexing
- Google Drive and Gmail OAuth integration
