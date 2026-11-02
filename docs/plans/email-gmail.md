---
status: proposed
adr: none
remaining: [decide-auth-path, google-verification-or-app-password, imap-option, takeout-import, label-mapping]
---

# Plan: Gmail and Google Workspace

**Today:** `gmail_scanner_isolate.dart` syncs through the **Gmail API** (`googleapis`, scope
`gmail.readonly`), using an OAuth client ID and secret the user configures in Settings.

Uses the [IMAP engine](email-imap-engine.md) for the IMAP option and
[file imports](email-file-imports.md) for Takeout.

## The problem to solve before shipping

`gmail.readonly` (and `https://mail.google.com/`, which IMAP over OAuth needs) are Google
**restricted scopes**. An app other people install needs:
- Google OAuth **app verification**;
- a yearly **CASA** security assessment by a Google-approved lab, costing roughly a few hundred
  to a few thousand dollars a year (third-party figures).

Whether an on-device app that never sends mail data to a server qualifies for a lighter review
or an exemption is unconfirmed **(verify with Google)**.

The current "bring your own OAuth client" setup avoids that, but at a cost. A Google Cloud
project in **Testing** status is capped at 100 users, shows an "unverified app" warning, and
issues refresh tokens that **expire after 7 days** **(verify)**. That's fine for development,
but too fragile for users.

## Options

| Path | Setup for the user | Our cost | Notes |
|---|---|---|---|
| **A. Gmail API, verified app** | One "Sign in with Google" click | Verification + yearly CASA | Best experience. Keeps label-native sync and `historyId` incremental sync. |
| **B. IMAP + app password** | Turn on 2-Step Verification, create an app password, paste it | None | Works for personal accounts today **(verify Google still offers app passwords)**. Workspace admins can disable them. |
| **C. Google Takeout (MBOX)** | Export Mail at takeout.google.com, pick the file | None | One-time backfill. Can be scheduled every 2 months for a year **(verify)**. |

**Recommendation:** ship **B + C** first: no Google review, works for most personal accounts.
Keep **A** for when we're ready to fund verification. Existing Gmail API collections keep
working for users who already set up their own client.

## B. Gmail over IMAP (registry entry)

- `imap.gmail.com:993`, TLS, username = full address, auth `appPassword`.
- Domains: `gmail.com`, `googlemail.com`. Custom domains are detected by MX `*.google.com` /
  `*.googlemail.com` (Workspace).
- **Setup steps:**
  1. Open **myaccount.google.com › Security**.
  2. Turn on **2-Step Verification** if it's off.
  3. Search for **App passwords**, create one named "My Data Studio", and paste the 16-character
     password here.
  4. If App passwords is missing: your Workspace admin has turned it off. Use Takeout instead.
- **Gmail quirks** (Gmail's IMAP extensions):
  - Sync only **`[Gmail]/All Mail`** (SPECIAL-USE `\All`), and read labels with
    **`X-GM-LABELS`**, so each message is downloaded once.
  - Labels map to `email_folders`; system labels (`\Inbox`, `\Sent`, `\Starred`) map to folder
    types.
  - Dedupe on **`X-GM-MSGID`**. Thread on **`X-GM-THRID`** → `emails.thread_id`.
  - Skip `[Gmail]/Spam` and `[Gmail]/Trash` by default.
  - Gmail has IMAP download limits (around 2.5 GB/day per account) **(verify)**. Throttle the
    backfill and resume the next day, showing "Paused: Gmail daily download limit".

## C. Google Takeout

- Steps: **takeout.google.com** › **Deselect all** › tick **Mail** (optionally choose labels) ›
  **Next** › **Export once** › **.zip** › **Create export**. Wait for the email, then download.
- Import with the MBOX importer ([email-file-imports.md](email-file-imports.md)). Takeout's
  `X-Gmail-Labels` header gives labels, and `X-GM-THRID` gives threads. Dedupe on Message-ID
  against an IMAP collection for the same address.

## Done when

- A personal Gmail user connects with an app password and gets every label as a folder, with no
  duplicate messages, and new mail every 15 minutes.
- A Workspace user whose admin blocks app passwords is told why, and pointed to Takeout.
- A Takeout import, plus a later IMAP connection, produces one copy of each message.
- The decision on path A (verification and CASA budget) is recorded here.
