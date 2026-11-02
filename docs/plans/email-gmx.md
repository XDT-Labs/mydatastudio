---
status: proposed
adr: none
remaining: [registry-entries, setup-steps, imap-disabled-detection, verify-settings]
---

# Plan: GMX, mail.com and WEB.DE

These three are run by the same company (United Internet / 1&1). Same rules, three registry
entries on the [IMAP engine](email-imap-engine.md).

| Brand | IMAP host | Domains |
|---|---|---|
| GMX (US/UK/…) | `imap.gmx.com` | `gmx.com`, `gmx.us`, `gmx.co.uk`, … |
| GMX (DE/AT/CH) | `imap.gmx.net` | `gmx.de`, `gmx.at`, `gmx.ch`, `gmx.net` |
| mail.com | `imap.mail.com` | `mail.com` and its ~200 vanity domains (`email.com`, `usa.com`, …) |
| WEB.DE | `imap.web.de` | `web.de` |

All on port 993, TLS, username = full address **(verify each host)**.

- **IMAP is off by default.** The user must turn it on: **Email › Settings › POP3 & IMAP ›
  Enable access to this account via POP3 and IMAP**.
- It **switches itself off again** after a long period without POP3/IMAP use. So a sync that
  starts failing months later is probably this, not a password change. The error message
  should say "IMAP access was turned off by GMX — turn it on again in settings", with the
  steps.
- **Login:** the account password, or an **application-specific password** when two-factor
  authentication is on (Security / login settings).
- **mail.com:** IMAP may be a paid (Premium) feature for free accounts **(verify)**. If so, say
  so on the card.
- **Setup steps:**
  1. Enable POP3 & IMAP (above).
  2. If you use two-factor authentication, create an application-specific password.
  3. Paste it here.

## Done when

Users of all three brands connect and sync. An account whose IMAP access lapsed gets the
specific "turn it back on" message.
