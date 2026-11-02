---
status: proposed
adr: none
remaining: [registry-entry, setup-steps, verify-settings]
---

# Plan: AOL Mail (incl. Verizon.net)

New provider on the [IMAP engine](email-imap-engine.md). There's no new code beyond a registry
entry and setup text.

- **Server:** `imap.aol.com:993`, TLS, username = full address **(verify the host)**.
- **Login:** **app password**. AOL says it "intentionally differs from your AOL account
  password". Same back end as Yahoo, so the same error handling.
- **Domains:** `aol.com`, `aim.com`, `love.com`, `games.com`, `wow.com`, and **`verizon.net`**
  (Verizon moved its mail to AOL) **(verify the list)**.
- **Setup steps:**
  1. Sign in at **login.aol.com** › **Account Security**.
  2. Click **Generate app password** (at the bottom). Choose **Other app** and name it "My Data
     Studio".
  3. Click **Generate** and paste the password here.
- **Folder quirks:** `Bulk` = spam (skip by default).

## Done when

An AOL or Verizon.net user connects via the shared setup flow and syncs all folders, with
incremental UID sync.
