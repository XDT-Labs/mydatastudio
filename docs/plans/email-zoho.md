---
status: proposed
adr: none
remaining: [registry-entries-per-region, setup-steps, free-plan-handling, verify-settings]
---

# Plan: Zoho Mail

New provider on the [IMAP engine](email-imap-engine.md).

- **Server depends on the account's data centre:** `imap.zoho.com` (US), `imap.zoho.eu`,
  `imap.zoho.in`, `imap.zoho.com.au`, `imap.zoho.jp`, `imap.zohocloud.ca`… **(verify the
  list)**. For an organisation (custom-domain) account, use `imappro.zoho.<region>`
  **(verify)**. Let the user pick their region, or detect it from MX (`mx.zoho.eu` → EU).
- **Port** 993, TLS, username = full address.
- **Login:** the account password, or an **app-specific password** when 2FA is on (the usual
  case).
- **IMAP must be switched on:** **Settings › Mail Accounts › IMAP › IMAP Access** ✓.
- **Free plan:** Zoho appears to have **removed IMAP/POP from new free accounts**, and sources
  conflict **(verify)**. If login fails with an access-not-allowed error, say so plainly. Offer
  Zoho's mailbox export (**Settings › Import/Export**, to EML or a zip) **(verify)** plus the
  [file import](email-file-imports.md).
- **Setup steps:**
  1. Enable **IMAP Access** in Zoho Mail settings.
  2. If you use two-factor authentication: **accounts.zoho.com › Security › App Passwords ›
     Generate New Password**.
  3. Choose your region and paste the password.
- **Domains:** `zoho.com`, `zohomail.com`, `zohomail.eu`, `zohomail.in`. Custom domains by MX
  `*.zoho.*`.

## Done when

A paid or IMAP-enabled Zoho user in any region connects and syncs. A free-plan user without
IMAP gets a clear explanation and the export path.
