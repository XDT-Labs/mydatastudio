# Scanning & Sync Lifecycle

This document explains how files, emails, and metadata are discovered, synchronized, and indexed in MyDataStudio.

## Overview

The scanning lifecycle has three phases:

1. **Registration** (app startup) — Scanners are instantiated but not started
2. **User-Triggered Sync** — Scanner runs when user navigates to collection or clicks "Sync"
3. **Incremental Indexing** — Embedding isolate generates vectors for newly-discovered items

## Phase 1: Registration (Startup)

At app launch, `DatabaseManager.startBackgroundServices()` calls `ScannerManager.registerScanners()`:

```dart
// In database_manager.dart
Future<void> startBackgroundServices() async {
  await scannerManager.registerScanners();
  // ... spawn embedding isolates ...
}

// In scanner_manager.dart
Future<void> registerScanners() async {
  final collections = await _collectionRepository.getCollections();
  for (final collection in collections) {
    final scanner = _createScannerForCollection(collection);
    _scanners[collection.id] = scanner;
    // NOT calling scanner.start() yet
  }
}
```

**Key point**: Scanners are created but **not started**. The app doesn't immediately scan or hit the network. This avoids:

- Blocking the UI on startup
- Hitting the network/filesystem aggressively
- Spawning many isolates when not needed

## Phase 2: User-Triggered Sync

When the user:

- Navigates to a file collection (e.g., "Local Files" folder)
- Navigates to an email folder
- Clicks a "Sync" or "Refresh" button
- Sets up a new collection

The corresponding scanner is started:

```dart
// In rx_files_page.dart or email_page.dart
final collection = await collectionRepository.getCollection(collectionId);
final scanner = scannerManager.getScanner(collection.id);
await scanner.start(force: true);  // Spawn isolate, begin sync
```

### Scanner Lifecycle: Local Files Example

```
User opens "Local Files" collection
  ↓
FilesPage requests files from repository
  ↓
Repository queries SQLite; table is empty or stale
  ↓
UI shows "Syncing..." message
  ↓
LocalFileIsolate.start() spawns a Dart isolate
  ↓
Isolate begins recursive filesystem walk:
  ├─ for each directory:
  │   ├─ Create `email_folder` entry (if new)
  │   ├─ Send write request to main isolate
  │   ├─ Wait for ack (folder ID)
  │
  └─ for each file:
      ├─ Extract metadata (size, modified date, MIME type)
      ├─ Generate thumbnail (if image)
      ├─ Extract EXIF (if image with geo tag)
      ├─ Batch 100 files into a single write request
      ├─ Send to main isolate via scan_write_relay.dart
      ├─ Wait for ack (generated IDs)
      ├─ Move to next batch
  ↓
Isolate completes, sets scanner.isScanning = false
  ↓
UI observers (RxFilesPage) are notified
  ↓
FilesPage re-queries repository and updates display
  ↓
User sees file list populated
```

### Scanner Lifecycle: Gmail Example

```
User opens Gmail account
  ↓
GmailScannerIsolate.start() spawns isolate
  ↓
Isolate authenticates using stored OAuth token
  ↓
Isolate lists Gmail labels via IMAP:
  ├─ for each label:
  │   ├─ Create `email_folder` entry
  │   ├─ Send write request to main isolate
  │
  └─ for each folder, fetch messages incrementally:
      ├─ Query `last_sync_uid` from database (read-only)
      ├─ Fetch new messages via IMAP FETCH <uid+1>:*
      ├─ Decode each MIME message
      ├─ Extract body, attachments, metadata
      ├─ Batch 50 messages into write request
      ├─ Send to main isolate
      ├─ Update `last_sync_uid` for folder
      ├─ Move to next batch
  ↓
Isolate completes, sets scanner.isScanning = false
  ↓
EmailEmbeddingIsolate wakes up and begins embedding new emails
  ↓
User can search emails
```

### Scanner Lifecycle: PST Import

PST import is **not** a registered scanner:

```
User selects "Import PST" from UI
  ↓
FilePicker opens, user selects .pst file
  ↓
OutlookPstScannerIsolate.start(pstPath) spawns isolate
  ↓
Isolate opens PST file via libpff-python
  ↓
Isolate iterates over messages in PST:
  ├─ for each message:
  │   ├─ Parse MIME structure
  │   ├─ Extract body, attachments, metadata
  │   ├─ Map PST folder → `email_folder` tree
  │   ├─ Batch 100 messages into write request
  │   ├─ Send to main isolate
  │   ├─ UI shows progress (e.g., "500 of 2500 messages")
  ↓
Isolate completes, sends completion event
  ↓
UI closes import dialog
  ↓
EmailEmbeddingIsolate picks up new emails
```

## Write Relay: Maintaining Order

Scanners don't write directly to SQLite. Instead, they send write requests over a **write-relay** channel to the main isolate.

See [Isolates & Write Relay](../architecture/isolates.md) for the detailed mechanics.

**Why order matters**: When importing files, a folder entry must be inserted before files that reference it as `parent_id`. The write relay ensures this ordering by:

1. Scanner awaits each write request's ack before sending the next message
2. Main isolate processes messages sequentially on its single AppDatabase connection
3. Writes are committed in order, so no foreign-key violations

## Phase 3: Incremental Indexing

Once files/emails are in the database, **embedding isolates** generate vector embeddings for semantic search.

### EmbeddingIsolate (Files)

```dart
// In embedding_isolate.dart
void embedLoop() async {
  while (true) {
    // Pause while any scanner is running
    while (scannerManager.isAnyScanning()) {
      await Future.delayed(Duration(seconds: 1));
    }
    
    // Find files without embeddings
    final filesToEmbed = await db.query(
      'SELECT * FROM files WHERE id NOT IN (SELECT file_id FROM file_embedding)',
      limit: 100,
    );
    
    if (filesToEmbed.isEmpty) {
      await Future.delayed(Duration(seconds: 5));
      continue;
    }
    
    // Generate embeddings
    for (final file in filesToEmbed) {
      final text = '${file.name}\n${file.description}\n${file.exif_data}';
      final embedding = await pythonService.generateEmbedding(text);
      
      // Send back to main isolate
      await mainIsolatePort.send({
        'type': 'embedding',
        'fileId': file.id,
        'vector': embedding,
      });
    }
  }
}
```

**Key behaviors**:

- **Pauses during scan**: If a scanner is running, embedding isolate sleeps to avoid contention
- **Batches embedding requests**: 100 files at a time
- **Sends vectors back to main**: Via `embedding_message_handler.dart`
- **Runs in background**: Doesn't block UI or other isolates

### EmailEmbeddingIsolate (Email)

Same pattern as EmbeddingIsolate, but for email messages:

```dart
// Find emails without embeddings
final emailsToEmbed = await db.query(
  'SELECT * FROM email WHERE id NOT IN (SELECT email_id FROM email_embedding)',
  limit: 100,
);

// Extract body text + metadata
for (final email in emailsToEmbed) {
  final text = '${email.subject}\n${email.body_text}';
  final embedding = await pythonService.generateEmbedding(text);
  
  // Send back to main isolate
  await mainIsolatePort.send({
    'type': 'email_embedding',
    'emailId': email.id,
    'vector': embedding,
  });
}
```

## Collection Status Tracking

As a scanner runs, it updates the collection's `is_scanning` flag:

```dart
// In local_file_isolate.dart
await writeViaMain({
  'type': 'updateCollectionStatus',
  'collectionId': collectionId,
  'isScanning': true,  // Scanner started
});

// ... scan files ...

await writeViaMain({
  'type': 'updateCollectionStatus',
  'collectionId': collectionId,
  'isScanning': false,  // Scanner completed
});
```

UI observers watch this flag and show/hide "Syncing..." messages:

```dart
// In rx_files_page.dart
scannerManager.isAnyScanning.listen((isScanning) {
  if (isScanning) {
    showSyncingPlaceholder();
  } else {
    reloadFileList();
  }
});
```

## Incremental Email Sync

Email scanners use **IMAP UID-based incremental sync** to avoid refetching old messages:

```dart
// In gmail_scanner_isolate.dart
final folder = await db.query(
  'SELECT * FROM email_folder WHERE id = ?',
  [folderId],
);

final lastSyncUid = folder['last_sync_uid'] ?? 0;

// Fetch only new messages (UID > lastSyncUid)
final newMessages = await imapClient.fetch(
  '${lastSyncUid + 1}:*',  // IMAP range syntax
  ['BODY[]', 'FLAGS', 'INTERNALDATE'],
);

// After processing new messages
await writeViaMain({
  'type': 'updateLastSyncUid',
  'folderId': folderId,
  'lastSyncUid': newMessages.last.uid,
});
```

This avoids downloading the same email twice and scales to large mailboxes.

## Storage & Resource Management

### Disk Usage

- **Files**: Thumbnails cached in `~/Library/Caches/<bundle-id>/Thumbnails/`
- **Email**: Attachments cached in `~/Library/Caches/<bundle-id>/EmailAttachments/`
- **Models**: GGUF models in `~/Library/Application Support/<bundle-id>/models/`

Cache cleanup runs periodically:

```dart
// Delete thumbnails older than 7 days
final oldThumbnails = await fs.listContents(thumbnailDir);
for (final thumbnail in oldThumbnails) {
  if (thumbnail.modifiedDate < DateTime.now().subtract(Duration(days: 7))) {
    await thumbnail.delete();
  }
}
```

### Memory Management

Isolates are resource-heavy, so:

- **One scanner per collection**: Don't spawn multiple scanners for the same collection
- **Staggered startup**: Embedding isolates start 500ms apart to avoid connection contention
- **Pause during scan**: Embedding isolate sleeps while scanner is running

## Troubleshooting Sync Issues

### "Sync never completes"

Check:

1. **Scanner isolate crashed**: Check logs for exceptions
2. **Write relay stuck**: Main isolate may be blocking; check SQLite locks
3. **Network timeout**: Email scanners may be waiting for IMAP response; increase timeout

### "Files disappeared after sync"

Possible causes:

1. **Files were deleted** from source (expected behavior)
2. **Collection path changed**: App can't find the files anymore
3. **Database corruption**: Try `make clean && make dev` to reset

### "Embeddings never generated"

Check:

1. **Python service down**: Embedding isolate needs HTTP access to `/util/embedding`
2. **Embedding isolate paused**: Waiting for scanner to finish? Check `isAnyScanning()`
3. **Model not downloaded**: Check model status in settings

## Next Steps

- **[Isolates & Write Relay](../architecture/isolates.md)** — Write consistency mechanics
- **[State Management](./state-management.md)** — How UI reacts to sync progress
- **[Modules: Files & Photos](../modules/files-and-photos.md)** — File scanning details
- **[Modules: Email](../modules/email.md)** — Email scanning details

## Source References

- **ScannerManager**: `/client/lib/scanners/scanner_manager.dart`
- **LocalFileIsolate**: `/client/lib/modules/files/services/scanners/local_file_isolate.dart`
- **GmailScannerIsolate**: `/client/lib/modules/email/services/scanners/gmail_scanner_isolate.dart`
- **OutlookPstScannerIsolate**: `/client/lib/modules/email/services/scanners/outlook_pst_scanner_isolate.dart`
- **EmbeddingIsolate**: `/client/lib/modules/files/services/embedding_isolate.dart`
- **EmailEmbeddingIsolate**: `/client/lib/modules/email/services/email_embedding_isolate.dart`
- **Write Relay**: `/client/lib/services/scan_write_relay.dart`, `/client/lib/services/embedding_message_handler.dart`
