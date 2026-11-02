---
status: proposed
adr: none
remaining: [public-client-pkce, own-entra-app, publisher-verification, move-to-imap-engine, m365-guidance]
---

# Plan: Outlook.com, Hotmail, Live and Microsoft 365

**Today:** `outlook_scanner_isolate.dart` syncs over **IMAP** with **XOAUTH2**
(`authenticateWithOAuth2`), scope `https://outlook.office.com/IMAP.AccessAsUser.All`, through
`LoginProviders.outlook` on `login.microsoftonline.com/<tenant>`. The user configures their own
Entra (Azure) client ID and secret in Settings.

Moves onto the [IMAP engine](email-imap-engine.md) as the `outlook` registry entry.

## Facts that shape this

- **OAuth2 is the only way in.** Microsoft turned off basic auth (passwords and app passwords)
  for IMAP on Outlook.com and Exchange Online **(verify the current state for consumer
  accounts)**. So unlike most providers here, there's no app-password fallback.
- Microsoft **supports public clients with PKCE**. A desktop app needs **no client secret**.
  `DesktopOAuthManager` currently refuses to start unless a secret is configured
  (`clientSecret.isEmpty` → `ProviderConfigurationException`). That check should only apply to
  providers that need it (Google).

## Work

1. **Ship our own Entra app registration** so users don't have to create one:
   - multi-tenant, plus personal Microsoft accounts (`/common` authority);
   - a public client, with redirect `http://localhost` (loopback; Entra allows any port for
     loopback **(verify)**);
   - scopes `https://outlook.office.com/IMAP.AccessAsUser.All offline_access openid email`.
   - Keep the "use my own client ID" override in Settings for power users and locked-down
     tenants.
2. **Publisher verification** (Microsoft Partner Network ID linked to xdtlabs) so the consent
   screen doesn't say "unverified". It needs a verified domain on the app registration.
3. **Refresh tokens:** store them with `CredentialCodec`, as today, and refresh before each
   sync. On `invalid_grant` → `needs_re_auth`.
4. **Registry entry:**
   - `outlook.office365.com:993`, TLS, username = full address, auth `xoauth2(outlook)`;
   - domains: `outlook.com`, `hotmail.com`, `hotmail.co.uk`, `live.com`, `msn.com`,
     `passport.com` and regional variants;
   - custom domains by MX `*.mail.protection.outlook.com` (Microsoft 365).
5. **Folder quirks:** Outlook localises folder names but advertises SPECIAL-USE, so use the
   engine's mapping. Skip `Junk Email`, `Deleted Items`, `Outbox` and `Conversation History` by
   default.

## Microsoft 365 (work and school accounts)

The same flow, but the tenant controls it. Admins can block user consent, so the user sees "Need
admin approval". IMAP can also be disabled per mailbox. Detect both errors and show a
plain-language explanation the user can forward to IT. **Microsoft Graph** (`Mail.Read`) is the
alternative for tenants that disable IMAP. It's deferred until users ask for it.

## Done when

- A personal Outlook.com user clicks **Sign in with Microsoft** (our app, no Settings step),
  consents, and syncs, with no client secret anywhere.
- Tokens refresh silently for months. A revoked consent shows "Reconnect".
- A blocked M365 tenant gets a clear explanation, not a generic error.
- Existing Outlook collections move onto `ImapScanner` without re-downloading.
