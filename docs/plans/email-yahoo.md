---
status: proposed
adr: none
remaining: [move-to-imap-engine, att-and-family-domains, setup-steps-refresh]
---

# Plan: Yahoo Mail (and Yahoo-hosted ISP mail)

**Today:** `yahoo_scanner_isolate.dart` syncs over IMAP (`imap.mail.yahoo.com:993`) with an
**app password** stored in `collections.access_token` (encrypted by `CredentialCodec`).

This is the reference provider for the [IMAP engine](email-imap-engine.md). Its isolate is the
starting point for `ImapScanner`.

## Work

1. **Move onto the engine:** the `yahoo` registry entry, auth `appPassword`. Existing
   collections keep their rows: same host, same UIDs. The first engine sync records each
   folder's `UIDVALIDITY` / last UID from the stored rows instead of re-downloading.
2. **Login:** stay on app passwords. Yahoo's OAuth for IMAP requires approval as a Yahoo partner
   **(verify)**, which isn't worth pursuing while app passwords work.
3. **Setup steps** (shown on the provider card):
   1. Open **login.yahoo.com/account/security**.
   2. Click **Generate app password** (older UI: **Manage app passwords**).
   3. Name it "My Data Studio", click **Generate**, and paste the password here.
4. **Domains:** `yahoo.com` and regional `yahoo.*`, `ymail.com`, `rocketmail.com`.
5. **Yahoo-hosted ISP mail.** These use Yahoo's back end but have their own IMAP host and
   password page **(verify each)**:
   - **AT&T** (`att.net`, `sbcglobal.net`, `bellsouth.net`, `pacbell.net`, `flash.net`,
     `swbell.net`, `wans.net`, `prodigy.net`): `imap.mail.att.net:993`, with a **secure mail
     key** from AT&T's profile page in place of an app password. Add as a separate `att`
     registry entry.
   - **Verizon** (`verizon.net`): moved to AOL Mail, so it's handled by the AOL plan
     ([email-aol.md](email-aol.md)).
6. **Folder quirks:** `Bulk Mail` is spam (`\Junk`), skipped by default. `Archive` is a normal
   folder.

## Done when

- Existing Yahoo collections run on `ImapScanner` with no re-download and no duplicate rows.
- New Yahoo and AT&T users connect from the shared setup flow with on-screen steps.
- UID-based incremental sync picks up new mail and flag changes without the one-day `SINCE`
  overlap.
