---
status: proposed
adr: none
remaining: [mbox-parser, eml-folder-import, import-ui, dedupe-with-imap, tuta-steps, olm-decision]
---

# Plan: Import mail files (MBOX, EML; PST exists)

For mail that can't be synced over IMAP, or to backfill quickly: Google Takeout, Apple Mail and
Thunderbird archives, Proton free accounts, Zoho free accounts, and **Tuta**, which has no IMAP
at all. PST import already exists (`outlook_pst_scanner_isolate.dart`, via the aiserver's
`/util/import/pst`). This plan adds MBOX and EML in the same style.

## Formats

| Format | Where it comes from | Notes |
|---|---|---|
| **MBOX** | Google Takeout (`All mail Including Spam and Trash.mbox`), Apple Mail (**Mailbox › Export Mailbox**, a `.mbox` bundle with an `mbox` file inside), Thunderbird (profile folder files with no extension), Proton/Tuta exports | Many messages concatenated, each starting with a `From ` line. Takeout files are often many GB. |
| **EML** | Single messages: Tuta export, Proton export, drag-and-drop from most clients | One RFC 5322 message per file. Usually a folder of them. |
| **PST** | Outlook for Windows | Existing importer. |
| **OLM** | Outlook for Mac archives | Zip of XML. Not supported yet; decide based on demand. |

## Import

- **Parser** (Dart, in an isolate; pure parsing, no network):
  - **MBOX:** stream the file line by line (never load a multi-GB Takeout into memory). Split on
    `From ` separator lines, and un-escape `>From ` (the mboxrd/mboxo variants) **(verify which
    variant each source uses)**.
  - **Both formats:** parse each message with `enough_mail`'s `MimeMessage` (already a
    dependency).
  - Headers that carry folder information:
    - Takeout's **`X-Gmail-Labels`** → folders;
    - **`X-GM-THRID`** → `thread_id`;
    - Apple Mail and Thunderbird folder names come from the file or bundle name.
- **Writes:** the PST isolate's pattern: one-time isolate, `writeViaMain()` for every write,
  attachments extracted into `files` with `email_id`, so attachments and inline images flow into
  Photos and search as today.
- **Identity and dedupe:** normalised **Message-ID** (fallback hash), as in the
  [IMAP engine](email-imap-engine.md). Importing a Takeout and then connecting the same Gmail
  account over IMAP, or importing the same file twice, yields one row per message. Track
  imported files by hash in `imported_exports` (shared with the social plans).
- **Collection:** each import becomes a collection named after the source (for example "Gmail
  Takeout — mike@…"), or merges into an existing collection for the same address, if the user
  picks one.

## UI

On **New email source**, a **"Import mail files"** card, using the same pattern as the social
setup panels:
1. **Pick a source** for tailored steps: Google Takeout, Apple Mail, Thunderbird, Proton, Tuta,
   Zoho, or "Other files". Steps:
   - **Google Takeout:** takeout.google.com › Deselect all › **Mail** › Export once ›
     download.
   - **Apple Mail:** select a mailbox › **Mailbox › Export Mailbox…** › choose a folder.
   - **Thunderbird:** find the profile folder (**Help › Troubleshooting Information › Profile
     Folder › Open**), then `Mail/` or `ImapMail/`.
   - **Tuta:** in the Tuta **desktop app**, select the messages (or a folder) › **Export**,
     which writes `.eml` files (MBOX may also be offered) **(verify)**.
   - **Proton (free):** use Proton's export tool **(verify the name and format)**.
2. **Choose files or folder:** `file_picker` (`.mbox`, `.eml`, `.zip`, or a folder). Validate it
   (counts messages; detects the format) and show "Google Takeout · 48,210 messages · 2007 –
   2026 · 6.1 GB".
3. **Import** with progress: messages, attachments, duplicates skipped.

## Tuta (Tutanota)

Tuta encrypts mail end-to-end and offers **no IMAP or POP**, so file export is the only path.
It's a one-time import, with an optional re-export reminder (monthly or quarterly).

## Done when

- A multi-GB Takeout MBOX imports with flat memory use, with labels as folders and threads
  intact.
- Apple Mail, Thunderbird and EML folder imports work. Tuta users have clear steps.
- Re-importing, or overlapping with an IMAP collection, creates no duplicates.
- Attachments from imported mail appear in Photos and search, like synced mail.
