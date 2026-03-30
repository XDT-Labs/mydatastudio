# Pivot Outlook Mail Integration to OAuth2

Microsoft has blocked Basic Auth (App Passwords) for Outlook, so we must pivot to OAuth2 (Modern Authentication).

## Success Criteria
- [x] Users can log in to Outlook via OAuth2.
- [x] Outlook scanner uses OAuth2 (IMAP.AccessAsUser.All) to access mail.
- [x] Legacy Outlook Basic Auth UI is removed.
- [x] All tests pass.

## Tasks
- [x] 1. Modify `client/lib/oauth/login_providers.dart` (Status: ✅ Implemented)
  - [x] Add `LoginProviders.outlook` case to `login`.
  - [x] Set scopes to `['offline_access', 'https://outlook.office.com/IMAP.AccessAsUser.All', 'openid', 'email', 'profile']`.
- [x] 2. Update `client/lib/modules/email/pages/new_email_page.dart` (Status: ✅ Implemented)
  - [x] Remove manual App Password form (`_OutlookTab`).
  - [x] Replace it with a button triggering OAuth flow (mirror `_GmailTab`).
  - [x] Set `oauthService: 'outlook'`.
- [x] 3. Update `client/lib/modules/email/services/scanners/outlook_scanner_isolate.dart` (Status: ✅ Implemented)
  - [x] Rename `appPassword` to `accessToken`.
  - [x] Use `client.authenticateWithOAuth2(emailAddress, accessToken)`.
- [x] 4. Remove unused UI widgets and their tests (Status: ✅ Deleted)
  - [x] Removed `client/lib/modules/email/widgets/email_setup/outlook_*_view.dart`
  - [x] Removed `client/test/modules/email/widgets/email_setup/outlook_*_view_test.dart`
- [x] 5. Verify the changes (Status: ✅ Verified with tests)
