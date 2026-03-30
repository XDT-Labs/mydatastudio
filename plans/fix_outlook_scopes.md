# Plan: Fix Outlook Login Flow Scopes

## 🔍 Analysis & Context
* **Objective:** Update the OAuth scopes for Outlook to ensure the access token is valid for both IMAP and Microsoft Graph API (User.Read).
* **Target File:** `client/lib/oauth/login_providers.dart`
* **Reasoning:** The current scopes include `openid`, `email`, and `profile`. These are often redundant when `https://graph.microsoft.com/User.Read` is requested, and specifically, the Graph API request `https://graph.microsoft.com/v1.0/me` requires `User.Read`.

## 📋 Micro-Step Checklist
- [x] Step 1: Update `scopes` for `LoginProviders.outlook` in `client/lib/oauth/login_providers.dart` (Status: ✅ Implemented)
- [ ] Step 2: Verify the change by reading the file back.

## 🧪 Testing Strategy
* Since this is a configuration change affecting an external OAuth flow, it is difficult to unit test without mocking the entire OAuth flow. 
* Verification will be done by code inspection and ensuring no syntax errors are introduced.
* Ideally, a manual test of the login flow would be performed, but as an AI I can only verify the code change.

## 🎯 Success Criteria
* The `scopes` getter for `LoginProviders.outlook` returns exactly:
  ```dart
  [
    'offline_access',
    'https://outlook.office.com/IMAP.AccessAsUser.All',
    'https://graph.microsoft.com/User.Read',
  ]
  ```
