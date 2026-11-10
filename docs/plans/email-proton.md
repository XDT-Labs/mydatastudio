---
status: proposed
adr: none
remaining: [bridge-registry-entry, starttls-local-cert, bridge-detection, free-plan-export-path, verify-settings]
---

# Plan: Proton Mail

Proton stores mail end-to-end encrypted, so its servers don't speak IMAP. Two paths:

## Paid plans: Proton Mail Bridge (IMAP on localhost)

**Proton Mail Bridge** is Proton's desktop app (macOS, Windows, Linux). It decrypts mail
locally and exposes an IMAP server on the user's own machine. It's **only available on paid
Proton plans**. This fits the [IMAP engine](email-imap-engine.md) as a registry entry with
two differences:

- **Server:** `127.0.0.1:1143`, **STARTTLS** (not implicit TLS) **(verify the default port)**.
- **Certificate:** Bridge presents a **self-signed certificate**. Accept it only for
  `127.0.0.1`/`localhost`, and pin its fingerprint on first connect (or import the certificate
  Bridge can export), so a different local process can't impersonate it. Never relax
  certificate checks for any other host.
- **Login:** username and **Bridge password**: a password Bridge generates, shown in Bridge's
  mailbox details. It's *not* the Proton account password.
- **Bridge must be running** for a sync to work. When the connection is refused, don't flag an
  error. Show "Proton Mail Bridge isn't running — open it to sync", and retry next schedule.
- **Setup steps:**
  1. Install **Proton Mail Bridge** from proton.me/mail/bridge and sign in.
  2. In Bridge, open your account and copy the **IMAP username**, **password** and **port**.
  3. Paste them here.
- **Detection:** the setup card can probe `127.0.0.1:1143` and pre-fill "Bridge detected".
- **Domains:** `proton.me`, `protonmail.com`, `protonmail.ch`, `pm.me`. Custom domains by MX
  `*.protonmail.ch`.

## Free plans: export, then file import

Free accounts can't use Bridge. Proton says users can "download all of your mail into your
client and export it from there", and Proton has offered an export tool (Import-Export app /
Easy Switch) that writes **EML** or **MBOX** **(verify the current tool and format)**. Import the
result with [email-file-imports.md](email-file-imports.md). It's a one-time backfill, with a
reminder to re-export.

## Done when

- A paid Proton user with Bridge running connects in a few clicks, and the sync survives Bridge
  restarts (pinned certificate, retry when Bridge is down).
- A free Proton user is told why Bridge isn't available and is walked through export plus file
  import.
