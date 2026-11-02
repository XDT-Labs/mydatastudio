---
status: proposed
adr: none
remaining: [registry-entry, setup-steps, delayed-activation-handling]
---

# Plan: Yandex Mail

New provider on the [IMAP engine](email-imap-engine.md).

- **Server:** `imap.yandex.com:993`, TLS. `imap.ya.ru` is the alternative host. Username =
  full address.
- **Login:** **app password** (Yandex ID › app type **Mail**). It's shown only once.
- **Two switches**, both required: in Yandex Mail **Settings › Email clients**, enable **"Use
  a mail client to retrieve your Yandex mail from the imap.yandex.com server via IMAP"** and
  **"App passwords and OAuth tokens"**.
- **New app passwords can take 2–3 hours to start working.** An authentication failure within a
  few hours of setup should say "Yandex may take a few hours to activate a new app password —
  we'll retry", and the scanner retries on schedule rather than flagging `needs_re_auth` straight
  away.
- **Domains:** `yandex.com`, `yandex.ru`, `ya.ru`, `yandex.by`, `yandex.kz`, `yandex.ua`,
  `narod.ru`.
- **Setup steps:**
  1. Turn on the two Email clients options above.
  2. Open **id.yandex.com › Security › App passwords**, create one for **Mail**, and paste it
     here.

## Done when

A Yandex user connects. A just-created app password that isn't active yet is retried, not
reported as wrong.
