---
status: in-progress
adr: none
remaining: [full-disk-access-check]
---

# Plan: iCloud Drive (sync folder only)

Apple offers **no public web API** for iCloud Drive to third-party apps. The only supported
route is the folder macOS already syncs: the
[sync-folder connector](files-sources-foundation.md) §4.

- **Location:** `~/Library/Mobile Documents/com~apple~CloudDocs/` (the "iCloud Drive" in
  Finder). App-specific containers sit alongside it as
  `~/Library/Mobile Documents/<team>~<bundle>/` (e.g. Pages, Numbers, Preview). Offer them as
  optional sub-collections with their app names. **Desktop & Documents**, if the user enabled
  it, appear inside iCloud Drive.
- **Online-only files are the norm.** Since macOS Sonoma, iCloud Drive uses **dataless files**
  (File Provider), and "Optimise Mac Storage" evicts them. So:
  - detect `SF_DATALESS` via the FFI `stat`; the scan reads metadata only;
  - handle **legacy stubs** (`.<name>.<ext>.icloud` hidden files) on older systems, shown under
    their real name (metadata only: macOS 15+ can't download them);
  - index online-only files by reading each one and evicting it again, and keep archive copies
    per the card's "Save a local copy of" choice (see the foundation plan).
- **Permissions:** the app may need the user to grant access to `~/Library/Mobile Documents`
  (a folder picker grant, or Full Disk Access if sandboxed) **(verify for our entitlements)**.
  Detect a denial and show the steps.
- **Photos:** iCloud **Photos** is a different service (the Photos library, not iCloud Drive).
  It's out of scope here; it has its own plan, [photos-apple-library.md](photos-apple-library.md).
- **Card copy:** "iCloud Drive syncs through macOS. Online-only files are downloaded briefly to
  index and archive them, then returned to online-only."

## Done when

iCloud Drive is detected and added in one click. Thousands of online-only files are listed
without downloading. Legacy stubs show correct names. The optional download budget works.
