---
status: proposed
adr: none
remaining: [registry-entry, setup-steps, revoked-password-handling, verify-settings]
---

# Plan: iCloud Mail

New provider on the [IMAP engine](email-imap-engine.md). Apple offers no OAuth for third-party
mail access, so it's an **app-specific password**.

- **Server:** `imap.mail.me.com:993`, TLS **(verify)**. IMAP only, no POP.
- **Username:** try the full address first. Some accounts only accept the part before the `@`
  for IMAP, so if login fails, retry once with that before reporting an error. Legacy
  `@me.com` / `@mac.com` addresses may need the primary Apple Account address.
- **Login:** **app-specific password** (requires two-factor authentication on the Apple
  Account). Up to 25 can exist at once.
- **Domains:** `icloud.com`, `me.com`, `mac.com`. iCloud+ custom domains are detected by MX
  `*.mail.icloud.com` **(verify)**.
- **Setup steps:**
  1. Open **account.apple.com** › **Sign-In and Security** › **App-Specific Passwords**.
  2. Click **+** (Generate an app-specific password), name it "My Data Studio", confirm with
     your Apple Account password, and paste the password here.
- **Gotcha to explain:** changing or resetting the Apple Account password **revokes every
  app-specific password**. On `AUTHENTICATIONFAILED`, the reconnect banner says exactly that.
- **Folder quirks:** `Sent Messages`, `Deleted Messages` and `Junk` all advertise SPECIAL-USE
  **(verify)**. Skip Junk and Deleted by default.

## Done when

An iCloud user connects with an app-specific password and syncs. After changing their Apple
Account password, they see a specific "create a new app-specific password" prompt, not a
generic failure.
