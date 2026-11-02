---
status: proposed
adr: none
remaining: [sync-folder-card, megacmd-evaluation]
---

# Plan: MEGA (sync folder; MEGAcmd later)

MEGA is end-to-end encrypted ("User Controlled Encryption"). Its official SDK is C++, with the
**MEGAcmd** command-line tool on top. There's no simple REST API for third-party clients.

- **v1: sync folder.** The MEGA desktop app syncs chosen folders (by default `~/MEGA` or a
  user-picked path; recent versions may also use File Provider **(verify)**). Detect a
  configured sync folder, or let the user pick it, and index it with the local scanner. The
  files are fully local (MEGA syncs real files, not placeholders, unless using its newer
  cloud-drive mode).
- **Later: MEGAcmd.** For cloud-only content: with MEGAcmd installed, the user runs
  `mega-login` once, and we run `mega-ls -lR` / `mega-get` from a background task. That's a
  local CLI, so no secrets reach us. Evaluate only if users ask for MEGA content that isn't
  synced. The MEGA SDK's licence terms need checking before bundling **(verify)**.

## Done when

A MEGA user adds their sync folder in one click.
