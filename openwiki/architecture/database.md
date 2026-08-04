# Database Design

MyDataStudio uses SQLite with the **resqlite** and **resqlite_vector** packages for local metadata and vector storage. The schema is declared as raw SQL DDL with no code generation or ORM.

## Schema & Initialization

The SQLite schema is defined as raw DDL strings in `/client/lib/database_manager.dart` under `AppDatabase.schemaDDL`. The schema includes:

- **Core tables**: `files`, `folders`, `email`, `email_attachments`, `email_folder`, `provider`, `aichat_*`
- **Metadata tables**: `file_embedding`, `email_embedding`, `file_tags`, `album`, `album_files`
- **User & Auth tables**: `app_user`, `oauth_token`
- **Vector storage**: `file_embedding.vector` (stored as BLOB, indexed via resqlite_vector)

### Schema Initialization

On every app open, `AppDatabase.init()` is called:

1. **Open SQLite connection** via resqlite
2. **Execute full schema DDL** (`CREATE TABLE IF NOT EXISTS ...` for each table)
3. **Check `PRAGMA user_version`** for schema version tracking
4. **Apply idempotent migrations** (e.g., `ALTER TABLE ... IF NOT EXISTS`, indexed vector table creation)

The schema is designed to be **idempotent**: running the DDL multiple times is safe, and migrations should use `IF NOT EXISTS` clauses. There is no incremental version counter or explicit migration framework like Flyway; instead, migrations are gated by ad-hoc `PRAGMA user_version` checks at runtime.

Example:

```dart
class AppDatabase {
  static const schemaDDL = [
    '''CREATE TABLE IF NOT EXISTS files (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      size_bytes INTEGER,
      modified_date INTEGER,
      -- ... other columns
    )''',
    // ... more DDL statements
  ];
  
  Future<void> init() async {
    final db = await openDatabase();
    for (final ddl in schemaDDL) {
      await db.execute(ddl);
    }
    // Check user_version and apply migrations if needed
    final version = await db.rawQuery('PRAGMA user_version');
    if (version.isEmpty || (version[0]['user_version'] as int) < 2) {
      // Apply schema changes
      await db.execute('ALTER TABLE files ADD COLUMN is_favorite INTEGER DEFAULT 0 IF NOT EXISTS');
      await db.execute('PRAGMA user_version = 2');
    }
  }
}
```

### Key Tables

#### `files`
Core metadata for local files and cloud documents.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PRIMARY KEY | Unique file ID |
| `collection_id` | INTEGER | Foreign key to `provider` (source collection) |
| `name` | TEXT | Display name |
| `mime_type` | TEXT | MIME type (image/jpeg, application/pdf, etc.) |
| `size_bytes` | INTEGER | File size in bytes |
| `modified_date` | INTEGER | Unix timestamp (ms) |
| `local_path` | TEXT | Path on device (may be NULL for cloud-only files) |
| `remote_path` | TEXT | Cloud path (Google Drive path, S3 URL, etc.) |
| `thumbnail_key` | TEXT | Cache key for generated thumbnail |
| `is_favorite` | INTEGER | Boolean (0/1) |
| `is_hidden` | INTEGER | Boolean (0/1) |

#### `file_embedding`
Vector embeddings for semantic search.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PRIMARY KEY | |
| `file_id` | INTEGER | Foreign key to `files` |
| `vector` | BLOB | Embedding vector (indexed via resqlite_vector) |
| `embedding_model` | TEXT | Which model generated this (e.g., "Qwen3-VL-2B") |
| `generated_at` | INTEGER | Unix timestamp (ms) |

The `vector` column is indexed by resqlite_vector for fast nearest-neighbor search.

#### `email`
Email message metadata.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PRIMARY KEY | |
| `provider_id` | INTEGER | Foreign key to `provider` (email account) |
| `folder_id` | INTEGER | Foreign key to `email_folder` |
| `subject` | TEXT | Email subject |
| `from_address` | TEXT | Sender |
| `to_address` | TEXT | Recipients (comma-separated or JSON array) |
| `sent_date` | INTEGER | Unix timestamp (ms) |
| `body_text` | TEXT | Plaintext body |
| `body_html` | TEXT | HTML body (if available) |
| `has_attachments` | INTEGER | Boolean (0/1) |
| `is_read` | INTEGER | Boolean (0/1) |
| `is_archived` | INTEGER | Boolean (0/1) |

#### `email_folder`
Email folder hierarchy (Gmail labels, Outlook folders, etc.).

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PRIMARY KEY | |
| `provider_id` | INTEGER | Foreign key to `provider` |
| `display_name` | TEXT | Folder name (e.g., "Inbox", "Sent") |
| `remote_id` | TEXT | Cloud folder ID (Gmail label ID, Outlook folder ID) |
| `parent_id` | INTEGER | Parent folder ID (for folder hierarchy) |
| `unread_count` | INTEGER | Number of unread messages |

#### `aichat_conversation` / `aichat_message`
AI chat history.

| Column (conversation) | Type | Notes |
|-------|------|-------|
| `id` | INTEGER PRIMARY KEY | |
| `title` | TEXT | Conversation title |
| `created_at` | INTEGER | Unix timestamp (ms) |
| `updated_at` | INTEGER | Unix timestamp (ms) |

| Column (message) | Type | Notes |
|-------|------|-------|
| `id` | INTEGER PRIMARY KEY | |
| `conversation_id` | INTEGER | Foreign key to `aichat_conversation` |
| `role` | TEXT | "user" or "assistant" |
| `content` | TEXT | Message text |
| `created_at` | INTEGER | Unix timestamp (ms) |

### Vector Search

The `file_embedding.vector` column is indexed by **resqlite_vector** for fast semantic search:

```sql
SELECT f.* FROM files f
INNER JOIN file_embedding fe ON f.id = fe.file_id
WHERE vector_match(fe.vector, ?, 100)  -- Match top-100 nearest neighbors
LIMIT 20;
```

This allows O(1) approximate nearest-neighbor search across millions of files.

## Data Models (Hand-Written)

Model classes are plain Dart with manual serialization. Each model in `/client/lib/models/tables/` mirrors a table in the schema.

Example (`/client/lib/models/tables/file.dart`):

```dart
class File {
  final int id;
  final int collectionId;
  final String name;
  final String? mimeType;
  final int? sizeBytes;
  final int? modifiedDate;
  final String? localPath;
  final String? remotePath;
  final String? thumbnailKey;
  final int? isFavorite;
  final int? isHidden;
  
  File({
    required this.id,
    required this.collectionId,
    required this.name,
    this.mimeType,
    this.sizeBytes,
    this.modifiedDate,
    this.localPath,
    this.remotePath,
    this.thumbnailKey,
    this.isFavorite,
    this.isHidden,
  });
  
  // Hand-written deserialization
  factory File.fromMap(Map<String, Object?> map) => File(
    id: map['id'] as int,
    collectionId: map['collection_id'] as int,
    name: map['name'] as String,
    mimeType: map['mime_type'] as String?,
    sizeBytes: map['size_bytes'] as int?,
    modifiedDate: map['modified_date'] as int?,
    localPath: map['local_path'] as String?,
    remotePath: map['remote_path'] as String?,
    thumbnailKey: map['thumbnail_key'] as String?,
    isFavorite: map['is_favorite'] as int?,
    isHidden: map['is_hidden'] as int?,
  );
  
  // Hand-written serialization
  Map<String, Object?> toMap() => {
    'id': id,
    'collection_id': collectionId,
    'name': name,
    'mime_type': mimeType,
    'size_bytes': sizeBytes,
    'modified_date': modifiedDate,
    'local_path': localPath,
    'remote_path': remotePath,
    'thumbnail_key': thumbnailKey,
    'is_favorite': isFavorite,
    'is_hidden': isHidden,
  };
}
```

### Why No Codegen?

Hand-written models give the codebase more **transparency** and **control**:

- Schema changes are explicit (edit DDL + model at the same time)
- No build step delays or codegen complexity
- Easier to reason about serialization edge cases (NULL handling, type conversions)
- No ORM magic hiding performance issues

The trade-off is manual upkeep: adding a column requires updating both the DDL and the model.

## Repositories (Data Access Layer)

Repositories in `/client/lib/repositories/` encapsulate all SQLite queries. They expose high-level methods like `getFilesInFolder()`, `upsertFile()`, and `deleteFile()`.

Example (`/client/lib/repositories/database_repository.dart`):

```dart
class DatabaseRepository {
  final AppDatabase _db;
  
  Future<List<File>> getFilesInFolder(int folderId) async {
    final rows = await _db.query(
      'files',
      where: 'folder_id = ?',
      whereArgs: [folderId],
    );
    return rows.map((row) => File.fromMap(row)).toList();
  }
  
  Future<void> upsertFile(File file) async {
    await _db.insert(
      'files',
      file.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  
  Future<int> deleteFile(int fileId) async {
    return await _db.delete(
      'files',
      where: 'id = ?',
      whereArgs: [fileId],
    );
  }
}
```

### Write Relay: Main Isolate Only

**Critical**: Only the main isolate's AppDatabase connection writes to SQLite. Background isolates (scanners, embeddings) open read-only connections and relay write requests back to the main isolate via `scan_write_relay.dart` and `embedding_message_handler.dart`.

See [Isolates & Write Relay](./isolates.md) for the consistency pattern.

## Schema Migration Strategy

When adding a new column or table:

1. **Add DDL** to `AppDatabase.schemaDDL` with `IF NOT EXISTS` clause:
   ```dart
   'ALTER TABLE files ADD COLUMN new_column TEXT DEFAULT NULL IF NOT EXISTS',
   ```

2. **Increment `PRAGMA user_version`** in an idempotent check:
   ```dart
   final version = await db.rawQuery('PRAGMA user_version');
   if ((version[0]['user_version'] as int) < 3) {
     await db.execute('ALTER TABLE files ADD COLUMN is_favorite INTEGER DEFAULT 0 IF NOT EXISTS');
     await db.execute('PRAGMA user_version = 3');
   }
   ```

3. **Update the model class** to include the new field:
   ```dart
   class File {
     // ... existing fields
     final int? isFavorite;  // New field
     
     File.fromMap(Map<String, Object?> map) => File(
       // ... existing mappings
       isFavorite: map['is_favorite'] as int?,
     );
     
     Map<String, Object?> toMap() => {
       // ... existing mappings
       'is_favorite': isFavorite,
     };
   }
   ```

4. **Test** by running the app on a fresh database and an existing database (to verify migration works).

## Performance Considerations

- **Vector search**: O(1) via resqlite_vector nearest-neighbor index
- **Folder hierarchy**: Indexed on `parent_id` for tree traversal
- **Full-text search**: Implemented via vector embeddings, not SQLite FTS (full-text search)
- **Batch operations**: Scanners batch insert/update many files at once to reduce transaction overhead

### SQLite Busy Timeout

The AppDatabase opens with a generous busy timeout to handle contention:

```dart
await database.open(path, onConfigure: (db) async {
  await db.execute('PRAGMA busy_timeout = 30000');  // 30s timeout
});
```

This allows the main isolate to hold a write lock while processing scanner relays without timing out.

## Next Steps

- **[Isolates & Write Relay](./isolates.md)** — How background isolates maintain data consistency
- **[Scanning & Sync Lifecycle](../data-flow/scanning.md)** — How files are discovered and stored
- **[State Management](../data-flow/state-management.md)** — How the UI queries and listens to changes

## Source References

- **Schema Definition**: `/client/lib/database_manager.dart` (search for `schemaDDL`)
- **Model Classes**: `/client/lib/models/tables/*.dart`
- **Repositories**: `/client/lib/repositories/database_repository.dart`, `/client/lib/repositories/collection_repository.dart`
- **Write Relay**: `/client/lib/services/scan_write_relay.dart`, `/client/lib/services/embedding_message_handler.dart`
