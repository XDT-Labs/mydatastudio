# Isolates & Write Relay

MyDataStudio uses **Dart isolates** for parallel background tasks (file scanning, email parsing, embedding generation). A critical design challenge is ensuring data consistency when multiple isolates access the same SQLite database.

The solution: **only the main isolate writes to SQLite**. Background isolates open read-only connections and relay write requests back to the main isolate.

## Background: The SQLITE_BUSY Problem

Before this refactor (PR #29), each isolate opened its own independent AppDatabase connection and wrote directly:

```dart
// ❌ OLD DESIGN (broken)
// Isolate A (scanner)
await scannerDb.insert('files', file.toMap());

// Isolate B (embedding)
await embeddingDb.update('file_embedding', {...});
```

This caused two problems:

1. **SQLITE_BUSY**: When multiple connections tried to write simultaneously, SQLite would timeout or return errors
2. **Silent failures**: A write could appear to succeed (e.g., `INSERT`) but silently affect zero rows if a guard clause (`WHERE EXISTS ...`) referenced data inserted by another connection that wasn't yet visible to this transaction

## The Write-Relay Pattern

**Solution**: Background isolates send write requests back to the main isolate, which executes them on its single connection.

### Architecture

```
┌──────────────────────┐     write request        ┌──────────────────────┐
│  Scanner Isolate     │─────────────────────────>│  Main Isolate        │
│  (read-only)         │                          │  (single writer)     │
│                      │<─────────────────────────│                      │
│                      │   write ack             │  SQLite              │
└──────────────────────┘     + updated fields    │  (single connection) │
                                                   └──────────────────────┘
```

When a scanner discovers files, it doesn't write to SQLite directly. Instead:

1. **Scanner sends a write request** over its control port: `{'type': 'dbWrite', 'table': 'files', 'data': {...}}`
2. **Main isolate receives** the request
3. **Main isolate executes** the write on its connection: `await db.insert('files', data)`
4. **Main isolate sends back** an ack with any generated IDs or updated fields
5. **Scanner receives** the ack and continues processing

### Implementations

#### Scanner Write Relay (`scan_write_relay.dart`)

Used by file scanners (local filesystem, Google Drive) and batch-file operations.

**Key interface**:

```dart
Future<Map<String, Object?>> writeViaMain(Map<String, Object?> message) {
  // Send message to main isolate via the shared ReceivePort
  // Wait up to 30s for ack
  // Return the ack data (generated IDs, updated counts, etc.)
}
```

**In the main isolate** (`database_manager.dart`):

```dart
Future<void> handleScanWriteMessage(Map<String, Object?> message) async {
  final type = message['type'] as String;
  switch (type) {
    case 'upsertFolder':
      await _db.insert('folders', message['data'] as Map<String, Object?>);
      break;
    case 'upsertFiles':
      // Batch insert files
      final files = message['files'] as List<Map<String, Object?>>;
      for (final file in files) {
        await _db.insert('files', file);
      }
      break;
    case 'updateCollectionStatus':
      final collectionId = message['collectionId'] as int;
      final isScanning = message['isScanning'] as bool;
      await _db.update(
        'provider',
        {'is_scanning': isScanning ? 1 : 0},
        where: 'id = ?',
        whereArgs: [collectionId],
      );
      break;
    // ... more cases
  }
}
```

**Ordering guarantee**: The isolate awaits each write's ack before sending the next message. This preserves insertion order (a folder must arrive before its files) without needing a separate mutex or queue.

#### Embedding Write Relay (`embedding_message_handler.dart`)

Used by `EmbeddingIsolate` (files) and `EmailEmbeddingIsolate` (emails).

**Key interface**:

```dart
// In the embedding isolate
Future<String> generateEmbedding(String text) async {
  // Local inference to generate embedding vector
  final vector = await model.embed(text);
  
  // Send back to main isolate
  final ack = await mainIsolatePort.send({
    'type': 'embedding',
    'fileId': fileId,
    'vector': vector,  // List<double>
  });
}
```

**In the main isolate** (`embedding_message_handler.dart`):

```dart
Future<void> handleEmbeddingMessage(Map<String, Object?> message) async {
  final fileId = message['fileId'] as int;
  final vector = (message['vector'] as List<dynamic>).cast<double>();
  
  // Insert into file_embedding table
  await _db.insert('file_embedding', {
    'file_id': fileId,
    'vector': vector,  // resqlite_vector handles serialization
    'embedding_model': 'Qwen3-VL-2B',
    'generated_at': DateTime.now().millisecondsSinceEpoch,
  });
}
```

## Write-Relay Startup

The write relay is set up in `database_manager.dart` during app initialization:

1. **Main isolate** opens its AppDatabase connection
2. **Main isolate** creates a ReceivePort for write messages
3. **Main isolate** spawns the scanner isolate, passing the SendPort
4. **Scanner isolate** uses the SendPort to send write requests (via `scan_write_relay.dart`)
5. **Main isolate** listens on its ReceivePort and processes messages synchronously

This ensures all writes happen on the main isolate's connection in order.

## Isolate Startup Staggering

Even with the write relay, opening multiple AppDatabase connections on the same file can cause contention at connection time. To minimize this:

```dart
// In DatabaseManager.startBackgroundServices()
await Future.delayed(Duration(milliseconds: 500)); // Stagger by 500ms
await embeddingIsolate.start();

await Future.delayed(Duration(milliseconds: 500));
await emailEmbeddingIsolate.start();
```

This gives each isolate time to open its connection and warm up before the next one tries.

## Exception Handling

If a write fails on the main isolate, the ack includes an error:

```dart
// If insert fails (e.g., constraint violation)
ack = {
  'status': 'error',
  'error': 'Unique constraint failed: files.id',
};

// Scanner receives the error and can decide to:
// - Retry
// - Log and skip
// - Bubble up to the UI
```

## Benefits

1. **No SQLITE_BUSY**: Only one writer (main isolate) → no contention
2. **No silent failures**: Write happens on the same connection that can see previous inserts
3. **Ordered execution**: Awaiting acks enforces write order (folder before files)
4. **Simpler testing**: Can mock the write relay for unit tests

## Trade-offs

1. **Main isolate bottleneck**: All writes funnel through one connection, which could limit throughput if many isolates are writing simultaneously
   - **Mitigated by**: Batch inserts (many files in one message) and scanner pausing during embedding (embeddings don't write while a scanner is running)

2. **Latency**: Each write incurs isolate communication overhead (SendPort → MessagePort → ReceivePort)
   - **Mitigated by**: Batching writes (e.g., insert 1000 files in a single message)

## Comparison to Alternatives

| Approach | Pros | Cons |
|----------|------|------|
| **Write Relay (current)** | No contention, ordered, simple | Main bottleneck, message overhead |
| **Connection Pool** | More parallelism | SQLITE_BUSY, guard-clause races |
| **Separate Database** | No contention | Separate schema per isolate, sync complexity |
| **Mutex on AppDatabase** | Ordered access | Deadlock risk, no parallelism |

The write relay is the simplest and most reliable for MyDataStudio's workload (batch file discovery is inherently bursty, not continuous).

## Recent Changes (PR #29)

Commit `7e9e22c` ("fix: route all scanner/embedding isolate writes through the main isolate") introduced the write-relay pattern across all isolates:

- **Before**: Each isolate opened its own AppDatabase connection and wrote directly
- **After**: All writes relay through main isolate via `scan_write_relay.dart` and `embedding_message_handler.dart`

This fixed silent write failures and SQLITE_BUSY errors that were breaking file discovery and embedding generation on large collections.

## Debugging the Write Relay

If writes are stuck or failing:

1. **Check main isolate logs** for exceptions in `handleScanWriteMessage()` or `handleEmbeddingMessage()`
2. **Check relay timeout** (default 30s in `scan_write_relay.dart`) — if scanner isolate is waiting too long, main isolate may be blocked
3. **Check SQLite busy timeout** (`PRAGMA busy_timeout`) — set to 30s in AppDatabase init
4. **Test in isolation**: Spawn a simple test isolate that just sends one write message and waits for ack

## Source References

- **Write Relay**: `/client/lib/services/scan_write_relay.dart`
- **Scanner Handler**: `/client/lib/database_manager.dart` (search for `handleScanWriteMessage`)
- **Embedding Handler**: `/client/lib/services/embedding_message_handler.dart`
- **Scanner Isolates**: `/client/lib/modules/files/services/scanners/local_file_isolate.dart`, `/client/lib/modules/files/services/scanners/google_file_scanner.dart`
- **Embedding Isolates**: `/client/lib/modules/files/services/embedding_isolate.dart`, `/client/lib/modules/email/services/email_embedding_isolate.dart`
- **Startup**: `/client/lib/database_manager.dart` (search for `startBackgroundServices`)

## Next Steps

- **[Database Design](./database.md)** — Schema, hand-written models, migration strategy
- **[Scanning & Sync Lifecycle](../data-flow/scanning.md)** — How isolates discover and index data
- **[State Management](../data-flow/state-management.md)** — How the UI reacts to isolate updates
