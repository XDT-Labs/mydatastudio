---
status: proposed
adr: none
remaining: [provider-registry, imap-scanner-refactor, uid-incremental-sync, special-use-folders, message-identity, periodic-trigger, setup-ui, generic-imap, imap-test-server]
---

# Plan: One IMAP engine for every email provider

The common way to **sync** mail is **IMAP**, not SMTP (SMTP only *sends*). Almost every
consumer provider offers IMAP, and they differ in just three things: the server address, how
you log in (an **app password** or **OAuth2 / XOAUTH2**), and a few folder quirks. This plan
turns the existing Yahoo and Outlook scanners into one provider-agnostic `ImapScanner`. Each
provider then becomes a small config entry plus setup instructions, described in its own plan
(see *Provider plans* at the end).

## Where we are

- `yahoo_scanner_isolate.dart` (873 lines) and `outlook_scanner_isolate.dart` (918 lines) are
  ~90% identical (about 75 differing lines). Both use `enough_mail`, connect to port 993, and
  sync with `UID SEARCH SINCE <date>`. They differ only in:
  - **login:** Yahoo uses `client.login(email, appPassword)`; Outlook uses
    `client.authenticateWithOAuth2(email, accessToken)`;
  - the host;
  - the `cleanupDeleted…` repository call.
- Gmail uses the **Gmail API** (`googleapis`, `gmail.readonly`), not IMAP. PST import is a
  separate one-time isolate.
- The app password is stored in `collections.access_token`, encrypted at rest by
  `CredentialCodec` (vault-backed). OAuth tokens use the same columns.
- Incremental sync is **day-granular** (`SINCE` minus 1 day). It re-fetches and re-checks a day
  of mail every run, and it misses flag changes and moves between folders.
- Deletions are only detected on a full sync (`cleanup_uids` with `UID SEARCH ALL`).

## The design

### 1. Provider registry

`modules/email/services/imap/imap_providers.dart`, one const entry per provider:

```dart
class ImapProviderConfig {
  final String id;               // 'yahoo', 'icloud', 'aol', …, 'generic'
  final String displayName;
  final String host;             // 'imap.mail.yahoo.com'
  final int port;                // 993
  final ImapSecurity security;   // tls | startTls (Proton Bridge)
  final ImapAuth auth;           // appPassword | xoauth2(LoginProviders.x) | bridgePassword
  final UsernameStyle username;  // fullAddress | localPart (iCloud accepts both)
  final Uri? appPasswordHelpUrl; // where the user creates the app password
  final List<String> setupSteps; // numbered on-screen instructions
  final List<String> domains;    // 'yahoo.com', 'ymail.com', … for autodetect
  final FolderQuirks quirks;     // e.g. Gmail's [Gmail]/All Mail duplicates
}
```

Add a provider by adding an entry, an icon and a setup-steps string. No new isolate.

### 2. `ImapScanner` (one isolate for all providers)

Merge the Yahoo and Outlook isolates into `imap_scanner_isolate.dart`, parameterised by
`ImapProviderConfig`. Keep their structure: the control port, `writeViaMain()` writes via
`SequentialWriteQueue`, and pausing embeddings while syncing. Keep `YahooScanner` /
`OutlookScanner` as thin registrations at first, so existing collections keep working, then
fold them into `ImapCollectionScanner(providerId)`.

**Auth adapter:** `appPassword` → `login()`; `xoauth2` → `authenticateWithOAuth2()`, refreshing
through the existing `DesktopOAuthManager` / `LoginProviders` flow before connecting.
`AUTHENTICATIONFAILED` → `needs_re_auth` → "Reconnect" banner, with provider-specific advice
("your app password may have been revoked when you changed your Apple ID password").

### 3. Incremental sync by UID, not by date

Per folder, store `(uid_validity, last_seen_uid, highest_mod_seq)` in a new `email_folder_sync`
table (or columns on `email_folders`):
- **New mail:** `UID FETCH <last_seen_uid+1>:*`. Exact, with no day of overlap to re-check.
- **`UIDVALIDITY` changed** (the server renumbered the folder): re-list UIDs and re-match
  existing rows by Message-ID. Don't re-download bodies we already have.
- **Flags, moves and deletes:** if the server advertises **CONDSTORE/QRESYNC**, use
  `CHANGEDSINCE <highest_mod_seq>` (with `VANISHED` under QRESYNC) to get changed flags and
  expunged UIDs cheaply. Otherwise run `UID SEARCH ALL` (UIDs only, cheap) once a day, and diff
  it against stored UIDs to find deletions.
- **Fallback:** keep the current `SINCE` path for servers that misreport UIDs **(verify which
  providers, if any)**.
- **Deletion policy:** today a server-side delete deletes the local row. For an *archive* that
  may be wrong. Make it a per-collection setting: **"Keep messages I delete in <provider>"**,
  defaulting to **on** for consistency with the social plans **(decide)**. When on, mark
  `is_deleted_on_server` instead of deleting.

### 4. Folders via SPECIAL-USE

Use RFC 6154 attributes (`\Sent`, `\Drafts`, `\Trash`, `\Junk`, `\Archive`, `\All`) instead of
English folder names, so localized accounts (e.g. "Gesendet") map correctly into
`email_folders.type`. Default to syncing everything except `\Junk` and `\Trash`, with a toggle
per folder. Skip `\All` when other folders are synced (Gmail-over-IMAP would otherwise
double-count).

### 5. Message identity and dedupe

The same message can arrive from two folders (Gmail labels), two accounts (forwarding), or an
IMAP sync *and* a PST/MBOX import of the same mailbox. Normalise `Message-ID` (lowercase,
trimmed brackets) and index `(collection_id, message_id)`. When `Message-ID` is missing, fall
back to a hash of `(Date, From, Subject, first 1 KB of body)`. Within a collection, one row per
message, with folder membership in a join table (or the existing `labels` column). Across
collections, keep both rows but link them, so search shows the message once **(decide in
unified-search terms)**.

### 6. Scheduling

Use the `ScannerManager` periodic trigger the social plans introduce (`Timer.periodic` per
collection). For email, default to **every 15 minutes** while the app is running, plus at
start. IMAP `IDLE` (push) is a later optimisation for the Inbox only.

### 7. Setup UI: one flow for all providers

`new_email_page.dart` today has per-provider views (`yahoo_idle_view.dart`, …). Replace them
with:
1. **"Enter your email address".** Autodetect the provider from the domain (`domains` in the
   registry). For a custom domain, look up its **MX** records (e.g. `*.google.com` → Gmail,
   `*.outlook.com` / `protection.outlook.com` → Microsoft, `*.icloud.com` → iCloud), and then
   try Mozilla's **ISPDB autoconfig** (`https://autoconfig.thunderbird.net/v1.1/<domain>`) for
   server settings **(verify the endpoint and its terms of use)**.
2. **Provider card:** logo, then either:
   - **OAuth** → a **Sign in with <provider>** button;
   - **app password** → numbered steps (the provider's `setupSteps`) with an **Open <provider>
     security settings** button (`appPasswordHelpUrl`) and a masked password field.
3. **Test connection:** connect, list folders and show "Connected · 14 folders · 48,210
   messages". Report errors with the provider's wording ("IMAP access is off — turn it on in
   GMX settings").
4. **Choose folders**, then **Start sync**.

The **"Other (IMAP)"** card asks for host, port, security, username and password, for any
provider not in the registry: ISPs (Comcast/Xfinity, Spectrum, Cox, …), web hosts, and
self-hosted servers.

### 8. Tests

- Integration tests against a **local IMAP server** in Docker (GreenMail or Dovecot) seeded with
  fixtures: UID incremental, `UIDVALIDITY` change, CONDSTORE flag change, expunge, SPECIAL-USE
  mapping in a non-English locale, a message with no `Message-ID`, a large attachment.
- Registry: every entry has host, port, auth, steps, and at least one domain. Autodetect maps
  sample addresses to the right provider.
- Regression: an existing Yahoo and Outlook collection, upgraded to `ImapScanner`, keeps its
  rows and doesn't re-download.

## Provider plans

Status of each is in [ROADMAP.md](../ROADMAP.md).

| Provider | Sync | Login | Plan |
|---|---|---|---|
| Gmail / Google Workspace | Gmail API (existing); IMAP + app password as an alternative | OAuth (needs Google verification) or app password | [email-gmail.md](email-gmail.md) |
| Outlook.com / Hotmail / Live / Microsoft 365 | IMAP (existing) | OAuth2 only | [email-outlook.md](email-outlook.md) |
| Yahoo Mail (incl. AT&T, Verizon/AOL-hosted) | IMAP (existing) | App password | [email-yahoo.md](email-yahoo.md) |
| AOL Mail | IMAP | App password | [email-aol.md](email-aol.md) |
| iCloud Mail | IMAP | App-specific password | [email-icloud.md](email-icloud.md) |
| Proton Mail | IMAP via **Proton Mail Bridge** (paid plans) | Bridge password | [email-proton.md](email-proton.md) |
| Fastmail | IMAP (JMAP later) | App password | [email-fastmail.md](email-fastmail.md) |
| Zoho Mail | IMAP (paid plans; free plan unclear) | App password | [email-zoho.md](email-zoho.md) |
| GMX / mail.com / WEB.DE | IMAP (must be switched on) | Password or app password | [email-gmx.md](email-gmx.md) |
| Yandex Mail | IMAP (must be switched on) | App password | [email-yandex.md](email-yandex.md) |
| Tuta (Tutanota) | **No IMAP** | — | [email-file-imports.md](email-file-imports.md) |
| Any other IMAP server / ISP | IMAP | Password or app password | "Other (IMAP)" above |
| Files: PST (existing), MBOX, EML | One-time import | — | [email-file-imports.md](email-file-imports.md) |
