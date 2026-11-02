---
status: proposed
adr: none
remaining: [sync-folder-card, dataless-handling, watch-sdk]
---

# Plan: Proton Drive (sync folder; SDK later)

Proton Drive is end-to-end encrypted. Proton's **Drive SDK** (JavaScript and C#, January 2026)
covers file operations, but **authentication for standalone third-party apps isn't supported
yet**, and Proton says it's "not yet officially supported for use by third parties". A
cryptography change is planned for late 2026 or early 2027. So:

- **v1: sync folder.** The Proton Drive for macOS app mounts a folder under
  `~/Library/CloudStorage/` **(verify the name)**. Index it with the
  [sync-folder connector](files-sources-foundation.md): decrypted files on the user's Mac, no
  sign-in, and dataless rules for online-only files.
- **Later: the SDK.** Revisit when Proton supports third-party auth. That would need a
  JavaScript or C# runtime (or a port), so the likely home is the aiserver (Python) via a
  bridge **(decide then)**.
- **Card copy:** "Proton Drive is end-to-end encrypted. We index the files the Proton Drive app
  has decrypted on this Mac."

## Done when

A Proton Drive user adds the folder in one click, and online-only files are listed without
downloading.
