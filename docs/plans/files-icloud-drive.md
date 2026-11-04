---
status: in-progress
adr: none
remaining: [download-for-indexing, full-disk-access-check]
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
  - detect `SF_DATALESS` via the FFI `stat` and index metadata only;
  - handle **legacy stubs** (`.<name>.<ext>.icloud` hidden files) on older systems, shown under
    their real name;
  - offer the optional bounded "download for indexing", explaining that it uses disk space.
- **Permissions:** the app may need the user to grant access to `~/Library/Mobile Documents`
  (a folder picker grant, or Full Disk Access if sandboxed) **(verify for our entitlements)**.
  Detect a denial and show the steps.
- **Photos:** iCloud **Photos** is a different service (the Photos library, not iCloud Drive).
  It's out of scope here. Users can point a local collection at an exported folder.
- **Card copy:** "iCloud Drive syncs through macOS. We index what's on this Mac. Online-only files
  are listed but not downloaded unless you choose."

## Done when

iCloud Drive is detected and added in one click. Thousands of online-only files are listed
without downloading. Legacy stubs show correct names. The optional download budget works.
