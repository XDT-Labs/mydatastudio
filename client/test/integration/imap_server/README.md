# IMAP test server

Disposable Dovecot 2.4.1 for IMAP integration tests (CONDSTORE/QRESYNC,
SPECIAL-USE). **Test only**: plaintext auth, no TLS, fake passwords, bound to
127.0.0.1. Storage is tmpfs, so every `up` starts with empty mailboxes.

```bash
make imap-test-up     # start and wait until healthy
make imap-test-down   # stop and discard all data
make test-imap        # up, run `-t imap` tests, down
```

- Host/port: `127.0.0.1:3143` (IMAP, no TLS)
- Users: `alice@test.local`, `bob@test.local`; password `testpass`
- Mailboxes (separator `/`): `INBOX`, `Drafts` (\Drafts), `Sent` (\Sent),
  `Trash` (\Trash), `Junk` (\Junk), `Archive` (\Archive), plus
  `Sent Items` (\Sent) and `Papierkorb` (\Trash) to test flag-vs-name mapping.

Tests tagged `imap` skip themselves when the port is unreachable, so plain
`flutter test` works without Docker. Use `test/helpers/imap_test_server.dart`
for connecting, seeding messages with explicit Message-IDs, and expunging UIDs.
Mailboxes are shared between tests: call `deleteAll` (or use a unique user/
mailbox) at the start of each test. Note UIDNEXT keeps growing after deletes.
