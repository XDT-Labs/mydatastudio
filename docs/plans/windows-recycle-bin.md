---
status: parked
adr: none
remaining: [windows-trash-channel]
---

# Recycle Bin support when Windows becomes a build target

_Moved from `TODO.md` (photos delete/hide work, 2026-08-15)._

"Delete file" in the photos module moves a local original to the macOS Trash
through a `NSFileManager.trashItem` method channel in `macos/Runner`. Dart has
no cross-platform "move to trash" API and there is no package for it in this
project, so that channel is macOS-only.

Today that is not a gap — `client/` has only a `macos/` platform directory. When
Windows is added:

- Implement the same channel name in the Windows runner using `IFileOperation`
  (or `SHFileOperation` with `FOF_ALLOWUNDO`) so deletes land in the Recycle Bin.
- Linux would need the XDG trash spec (`~/.local/share/Trash`) if it is ever a
  target.
- The Dart side already degrades safely: when the channel is missing the file is
  left on disk and only the database row is marked `is_user_deleted`, so nothing
  is destroyed on a platform without an implementation. Do **not** "fix" that by
  falling back to `io.File.delete()` — a silent permanent delete where the user
  was promised a recoverable one is worse than leaving the file in place.

Drive files are unaffected: `GoogleDriveProvider.deleteFile` sets `trashed = true`
through the Drive API, which is platform-independent.
