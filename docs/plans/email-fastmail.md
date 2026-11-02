---
status: proposed
adr: none
remaining: [registry-entry, setup-steps, jmap-later, verify-settings]
---

# Plan: Fastmail

New provider on the [IMAP engine](email-imap-engine.md).

- **Server:** `imap.fastmail.com:993`, TLS, username = full address.
- **Login:** **app password**. Fastmail requires one for third-party clients **(verify)**.
- **Domains:** `fastmail.com`, `fastmail.fm` and Fastmail's other legacy domains. Custom domains
  by MX `*.messagingengine.com`.
- **Setup steps:**
  1. In Fastmail, open **Settings › Privacy & Security › Manage app passwords and access**
     **(verify the path)**.
  2. Create a new app password with **IMAP** access (read-only if offered), name it "My Data
     Studio", and paste it here.
- Fastmail supports CONDSTORE/QRESYNC well **(verify)**, so it's a good second test target for
  the engine's flag and expunge sync.

## Later: JMAP

Fastmail created **JMAP** (RFC 8620/8621), a JSON-over-HTTP mail API with efficient change
sync (`Email/changes`), authorised by an API token. It's faster than IMAP for large mailboxes.
Consider a `JmapScanner` only if IMAP proves slow, and if other JMAP providers (e.g. Stalwart
servers) make it worth building.

## Done when

A Fastmail user connects with an app password and syncs, with flag changes and deletions picked
up incrementally.
