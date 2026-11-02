---
status: proposed
adr: none
remaining: [sync-folder-card]
---

# Plan: Sync.com (sync folder only)

Sync.com is end-to-end encrypted, and offers **no public API** (none found in research). The
desktop app syncs a folder (by default `~/Sync` **(verify)**).

- **v1: sync folder.** Detect `~/Sync` (or let the user pick the folder) and index it with the
  [sync-folder connector](files-sources-foundation.md). Its "Vault" (cloud-only) content isn't
  on disk, and so isn't indexed; say so on the card.
- Revisit if Sync.com publishes an API.

## Done when

A Sync.com user adds their folder in one click, with the Vault limitation explained.
