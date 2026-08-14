# Email Module

The **Email** module archives and searches email from multiple providers. It supports Gmail (OAuth2 + IMAP), Yahoo (OAuth2 + IMAP), Outlook (live IMAP), and Outlook PST file imports.

## Directory Structure

```
modules/email/
  pages/
    email_page.dart                 # Main email browser
    new_email_page.dart             # Email account setup wizard
  services/
    scanners/
      gmail_scanner_isolate.dart    # Gmail IMAP scanner (isolate)
      yahoo_scanner_isolate.dart    # Yahoo IMAP scanner (isolate)
      outlook_scanner_isolate.dart  # Outlook IMAP scanner (isolate)
      outlook_pst_scanner_isolate.dart # Outlook PST import (isolate)
    email_embedding_isolate.dart    # Email content vector embedding (isolate)
    email_decoding_helper.dart      # MIME decoding, attachment extraction
    email_folder_repository.dart    # Folder hierarchy queries
    email_folder_upsert_service.dart # Folder creation/sync
    email_repository.dart           # Email message queries
    email_upsert_service.dart       # Message insert/update
    get_email_folders_service.dart  # Fetch folder tree
    get_emails_service.dart         # Fetch messages with pagination
    inline_attachment.dart          # Inline image handling (CID resolver)
  widgets/
    email_detail/
      attachment_thumbnail_widget.dart  # Attachment preview
      email_attachments_section.dart    # All attachments list
      email_detail_drawer.dart          # Right sidebar with message body
    email_drawer/
      email_folder_tile_widget.dart     # Single folder in tree
      email_folder_tree.dart            # Hierarchical folder navigation
    email_setup/
      gmail_configure_view.dart         # Gmail OAuth + IMAP setup
      outlook_configure_view.dart       # Outlook IMAP setup (credentials)
      yahoo_idle_view.dart              # Yahoo OAuth setup
    email_table.dart                # Main email list (subject, from, date, flags)
    email_drawer.dart               # Left nav with folder tree
    scanning_placeholder_widget.dart # "Syncing..." message
```

## Supported Email Providers

| Provider | Auth Method | Transport | Notes |
|----------|---|---------|-------|
| **Gmail** | OAuth2 | IMAP | Requires Gmail API credentials; labels are folders |
| **Yahoo** | OAuth2 | IMAP | Yahoo Mail Plus or equivalent required |
| **Outlook** | Username/Password | IMAP | Live Outlook.com or on-prem Exchange |
| **Outlook PST** | File Import | Libpff | One-time import; not a registered scanner |

## Scanners

### Gmail Scanner (`gmail_scanner_isolate.dart`)

Spawned when a Gmail account is configured. It:

1. **Authenticates** via stored OAuth2 tokens
2. **Lists Gmail labels** via IMAP folder commands
3. **Syncs folders hierarchically**: Inbox, Sent, Drafts, custom labels, nested labels
4. **Fetches messages** incrementally (by UID, tracks sync state in `email_folder.last_sync_uid`)
5. **Parses email** (MIME decoding, attachments, CID inline images)
6. **Sends batch upserts** back to main isolate via write relay

Key features:

- **IMAP RFC4551** (CONDSTORE): Incremental sync via UID tracking
- **Attachment handling**: Extracts MIME parts, caches in temp directory
- **Inline CID images**: Stores Base64-encoded images in-message
- **Unicode support**: Handles non-ASCII subjects, bodies, from/to addresses

### Yahoo & Outlook IMAP Scanners

Similar to Gmail but with different credential/auth flow:

- **Yahoo**: OAuth2 token refresh; IMAP labels instead of Gmail-specific API
- **Outlook**: Username/password stored in secure vault; IMAP folder structure

### Outlook PST Scanner (`outlook_pst_scanner_isolate.dart`)

One-time import (not a registered `ScannerManager` scanner; user-triggered from UI):

1. **User selects .pst file** from file picker
2. **PST parser** spawned in isolate via libpff-python binding
3. **Extract email messages** from PST folders (tree structure preserved)
4. **Send upserts** to main isolate via write relay
5. **UI shows progress** (e.g., "Processing: 1234 of 5000 messages")

Key points:

- **Streaming**: libpff iterates over PST contents; we batch parse
- **Folder hierarchy**: PST folder structure mapped to `email_folder` tree
- **Attachment extraction**: MIME parts preserved from PST

## Email Database Schema

### `email` Table

Core email metadata:

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PRIMARY KEY | Unique email ID |
| `provider_id` | INTEGER | FK to `provider` (email account) |
| `folder_id` | INTEGER | FK to `email_folder` |
| `subject` | TEXT | Email subject |
| `from_address` | TEXT | Sender (e.g., "user@example.com" or "Name <user@example.com>") |
| `to_address` | TEXT | Recipients (comma-separated or JSON array) |
| `cc_address` | TEXT | CC recipients |
| `bcc_address` | TEXT | BCC recipients |
| `sent_date` | INTEGER | Unix timestamp (ms) |
| `received_date` | INTEGER | Unix timestamp (ms) when arrived at server |
| `body_text` | TEXT | Plaintext body (for search) |
| `body_html` | TEXT | HTML body (for display) |
| `has_attachments` | INTEGER | Boolean (0/1) |
| `is_read` | INTEGER | Boolean (0/1) |
| `is_archived` | INTEGER | Boolean (0/1) / Soft-delete flag |
| `is_starred` | INTEGER | Boolean (0/1) |
| `size_bytes` | INTEGER | Raw message size |
| `remote_id` | TEXT | Provider-specific UID (Gmail UID, PST entry ID, etc.) |

### `email_folder` Table

Folder hierarchy (Gmail labels, Outlook folders, etc.):

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PRIMARY KEY | |
| `provider_id` | INTEGER | FK to `provider` |
| `display_name` | TEXT | Folder/label name (e.g., "Inbox", "[Gmail]/All Mail") |
| `remote_id` | TEXT | Provider folder ID (Gmail label ID, IMAP mailbox name) |
| `parent_id` | INTEGER | FK to parent `email_folder` (for nested labels/folders) |
| `unread_count` | INTEGER | Cached unread message count |
| `total_count` | INTEGER | Total messages in folder |
| `last_sync_uid` | INTEGER | Last synced IMAP UID (for incremental sync) |
| `last_sync_date` | INTEGER | Last sync timestamp (ms) |

### `email_attachment` Table

Attachment metadata:

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PRIMARY KEY | |
| `email_id` | INTEGER | FK to `email` |
| `filename` | TEXT | Original filename |
| `mime_type` | TEXT | MIME type (application/pdf, image/jpeg, etc.) |
| `size_bytes` | INTEGER | Attachment size |
| `local_path` | TEXT | Path to cached attachment on disk |
| `is_inline` | INTEGER | Boolean (0/1) — is it an inline image (CID)? |
| `content_id` | TEXT | CID for inline images (e.g., "image001@01D5A1B2.6C4B1AB0") |

## Email Content Embedding

`email_embedding_isolate.dart` generates semantic embeddings for email bodies:

1. **Watches `email` table** for rows without `email_embedding`
2. **Extracts plaintext body** (strip HTML, handle quoted replies)
3. **Generates embedding** via Python service (Qwen3-VL)
4. **Sends vector** back to main isolate
5. **Stores in `email_embedding` table**

This enables semantic search ("Find emails about project X") without full-text indexing.

## Email Parsing & MIME Decoding

`email_decoding_helper.dart` handles:

- **MIME parsing**: Parse multipart messages, extract body/attachments
- **Character encoding**: Handle various charsets (UTF-8, ISO-8859-1, etc.)
- **Quoted-printable**: Decode transfer encoding
- **Base64 attachments**: Decode and save to temp directory
- **CID inline images**: Extract and embed Base64 in message body

Example:

```dart
final decoded = await EmailDecodingHelper.decodeMimeMessage(rawMessageBytes);
// Returns: {
//   'subject': '...',
//   'from': '...',
//   'to': [...],
//   'bodyText': '...',
//   'bodyHtml': '<html>...</html>',
//   'attachments': [
//     {'filename': 'report.pdf', 'data': <bytes>, 'mimeType': 'application/pdf'},
//     // ...
//   ],
//   'inlineImages': {
//     'image001@01D5A1B2': '<base64-encoded-png>',
//   },
// }
```

## UI: Email Pages

### Email Page (`email_page.dart`)

Main email browser:

- **Folder tree** (left sidebar): Gmail labels, Outlook folders, nested hierarchy
- **Email list** (center): Subject, from, date, unread flag, attachment badge
- **Message detail** (right sidebar): Full HTML body, attachments, inline images
- **Search**: Full-text + semantic search across all accounts

### Email Setup Wizard (`new_email_page.dart`)

Account configuration:

1. **Provider selection**: Gmail, Yahoo, Outlook, PST import
2. **Auth flow**:
   - Gmail/Yahoo: OAuth2 consent screen → token stored securely
   - Outlook: Username/password → token fetched via IMAP auth
3. **Folder sync**: Initial folder listing + sync status
4. **First sync**: Start incremental sync with progress updates

## Inbox Folder Synchronization

When a user clicks "Sync" or navigates to a folder:

1. **Scanner registers** with ScannerManager (if not already)
2. **ScannerManager.start()** spawns the scanner isolate
3. **Scanner connects** to IMAP server, authenticates
4. **Scanner lists folders** and creates `email_folder` entries
5. **Scanner syncs each folder**:
   - Query `last_sync_uid` from database
   - Fetch new messages via IMAP `FETCH <last_uid+1>:*`
   - Parse each message (MIME decoding, attachments)
   - Send batch upserts to main isolate
6. **EmailEmbeddingIsolate picks up** new messages and generates vectors
7. **UI updates** via RxService (observable email list)

**Incremental sync** via UID tracking avoids refetching old messages.

## PST File Import Workflow

PST import is **not** a registered scanner; it's a one-time import triggered from the UI:

1. **User selects file** from file picker
2. **UI spawns scanner isolate** with PST path
3. **PST parser** (via Python libpff binding) iterates over messages
4. **Each message is parsed**:
   - Extract MIME structure
   - Decode body/attachments
   - Map PST folder → `email_folder` entry
5. **Batches sent** to main isolate every N messages
6. **Progress updates** shown to user (e.g., "Importing 2345/5000 messages")
7. **On completion**: Messages are now searchable & embedded

Key difference from incremental scanners: PST is a **one-time, full-content import**, not a continuous sync.

## Performance & Caching

### Attachment Caching

Attachments are cached locally:

- **On download**: Save to `~/Library/Caches/<bundle-id>/EmailAttachments/<hash>/`
- **On display**: Load from cache; re-download if missing
- **On close**: Cleanup old cache files (older than 7 days)

### Incremental Sync

Folders are synced incrementally using IMAP UID:

- **First sync**: Fetch all messages (up to a limit, e.g., last 1 year)
- **Subsequent syncs**: Only fetch messages with UID > `last_sync_uid`
- **Limit old messages**: Don't sync messages older than configurable threshold (default: 5 years)

### Pagination

Email list in UI is paginated:

- **Initial load**: 50 recent messages
- **On scroll**: Load next 50 (lazy loading)
- **Search results**: 20 results, with "Load more" button

## Troubleshooting

### "IMAP connection failed"

- Check username/password (Outlook)
- Check OAuth token expiration (Gmail/Yahoo) — should auto-refresh
- Check network connectivity
- Gmail: Ensure "Less secure app access" is enabled (or use app-specific password)

### "Attachment failed to download"

- Attachment cache full? Check `~/Library/Caches/<bundle-id>/EmailAttachments/`
- Network issue during download? Retry via UI button
- Corrupted attachment? Marked as failed, can skip

### "PST import stuck"

- Check Python service logs (`/tmp/aiserver.log`)
- Verify PST file is not corrupted (try opening in Outlook)
- Increase isolate timeout (default 30s per batch; configurable)

## Next Steps

- **[Files & Photos](./files-and-photos.md)** — File module overview
- **[AI Chat](./aichat.md)** — Semantic search across email
- **[Scanning & Sync](../data-flow/scanning.md)** — How email is discovered and indexed

## Source References

- **Email Module**: `/client/lib/modules/email/`
- **Scanners**: `/client/lib/modules/email/services/scanners/`
- **Email Repositories**: `/client/lib/modules/email/services/email_repository.dart`, `/client/lib/modules/email/services/email_folder_repository.dart`
- **MIME Decoding**: `/client/lib/modules/email/services/email_decoding_helper.dart`
- **Embedding**: `/client/lib/modules/email/services/email_embedding_isolate.dart`
- **PST Parsing (Python)**: `/aiserver/src/aichat/pst_parser.py`
- **Tests**: `/client/test/modules/email/` (100+ email-specific tests)
