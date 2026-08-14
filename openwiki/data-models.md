# Data Models & Database Schema

My Data Studio uses **SQLite** with **resqlite** (Rust bindings) and **resqlite_vector** for vector storage. The schema is hand-maintained in `database_manager.dart` with no ORM codegen.

---

## Core Concepts

### Why Hand-Written Schema?

- **Full Control** — Explicit indices, constraints, and performance tuning without codegen complexity
- **Vector Support** — Seamless integration with resqlite_vector for semantic search
- **Custom Migrations** — Idempotent `ALTER TABLE` migrations with version gates
- **No Codegen Overhead** — Updates are simple text edits, not full code generation

### Schema Definition

The entire schema is declared in `client/lib/database_manager.dart`:

```dart
const String schemaDDL = '''
  CREATE TABLE IF NOT EXISTS app_user (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    storage_path TEXT
  );
  
  CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT UNIQUE NOT NULL,
    size INTEGER,
    mime_type TEXT,
    folder_id TEXT,
    collection_id TEXT NOT NULL,
    is_favorite INTEGER DEFAULT 0,
    ... more columns
  );
  
  CREATE INDEX idx_files_collection_id ON files(collection_id);
  CREATE INDEX idx_files_folder_id ON files(folder_id);
  ...
''';
```

### Migration Pattern

Migrations are idempotent and gated by `PRAGMA user_version`:

```dart
Future<void> _runMigrations(Database db) async {
  final version = await _getPragmaUserVersion(db);
  
  // Migration 1: Add is_favorite column
  if (version < 1) {
    await db.execute(
      'ALTER TABLE files ADD COLUMN is_favorite INTEGER DEFAULT 0'
    );
    await _setPragmaUserVersion(db, 1);
  }
  
  // Migration 2: Add file_tags table
  if (version < 2) {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS file_tags (
        id TEXT PRIMARY KEY,
        file_id TEXT NOT NULL,
        tag TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(file_id, tag),
        FOREIGN KEY(file_id) REFERENCES files(id)
      )
    ''');
    await _setPragmaUserVersion(db, 2);
  }
}
```

---

## Tables & Models

### app_user

User account and login state.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `email` | TEXT UNIQUE NOT NULL | Email address (unique per device) |
| `password_hash` | TEXT NOT NULL | Salted hash (not used if OAuth only) |
| `created_at` | INTEGER NOT NULL | Timestamp (seconds) |
| `storage_path` | TEXT | Path to user's storage directory |

**Dart Model:**

```dart
class AppUser {
  final String id;
  final String email;
  final String passwordHash;
  final int createdAt;
  final String? storagePath;

  AppUser({
    required this.id,
    required this.email,
    required this.passwordHash,
    required this.createdAt,
    this.storagePath,
  });

  factory AppUser.fromMap(Map<String, dynamic> map) => AppUser(
    id: map['id'],
    email: map['email'],
    passwordHash: map['password_hash'],
    createdAt: map['created_at'],
    storagePath: map['storage_path'],
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'email': email,
    'password_hash': passwordHash,
    'created_at': createdAt,
    'storage_path': storagePath,
  };
}
```

### files

File metadata for all discovered files (local, Google Drive, email attachments).

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `name` | TEXT NOT NULL | Filename or display name |
| `path` | TEXT UNIQUE NOT NULL | Full path (local) or cloud URL |
| `size` | INTEGER | File size in bytes |
| `mime_type` | TEXT | MIME type (e.g., "image/jpeg") |
| `folder_id` | TEXT | Parent folder ID |
| `collection_id` | TEXT NOT NULL | Collection reference |
| `is_favorite` | INTEGER DEFAULT 0 | Boolean (0/1) |
| `created_at` | INTEGER | Created timestamp (seconds) |
| `modified_at` | INTEGER | Last modified timestamp (seconds) |
| `source_type` | TEXT | "local", "google_drive", "email", etc. |

**Indices:**

```sql
CREATE INDEX idx_files_collection_id ON files(collection_id);
CREATE INDEX idx_files_folder_id ON files(folder_id);
CREATE INDEX idx_files_mime_type ON files(mime_type);
CREATE INDEX idx_files_created_at ON files(created_at DESC);
```

**Dart Model:**

```dart
class File {
  final String id;
  final String name;
  final String path;
  final int? size;
  final String? mimeType;
  final String? folderId;
  final String collectionId;
  final bool isFavorite;
  final int? createdAt;
  final int? modifiedAt;
  final String? sourceType;

  File({
    required this.id,
    required this.name,
    required this.path,
    this.size,
    this.mimeType,
    this.folderId,
    required this.collectionId,
    this.isFavorite = false,
    this.createdAt,
    this.modifiedAt,
    this.sourceType,
  });

  factory File.fromMap(Map<String, dynamic> map) => File(
    id: map['id'],
    name: map['name'],
    path: map['path'],
    size: map['size'],
    mimeType: map['mime_type'],
    folderId: map['folder_id'],
    collectionId: map['collection_id'],
    isFavorite: map['is_favorite'] == 1,
    createdAt: map['created_at'],
    modifiedAt: map['modified_at'],
    sourceType: map['source_type'],
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'path': path,
    'size': size,
    'mime_type': mimeType,
    'folder_id': folderId,
    'collection_id': collectionId,
    'is_favorite': isFavorite ? 1 : 0,
    'created_at': createdAt,
    'modified_at': modifiedAt,
    'source_type': sourceType,
  };
}
```

### folders

Directory/collection structure.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `name` | TEXT NOT NULL | Folder name |
| `path` | TEXT | Full path (local) or cloud path |
| `parent_id` | TEXT | Parent folder ID (for hierarchies) |
| `collection_id` | TEXT NOT NULL | Collection reference |

### file_embeddings

Vector embeddings for semantic search (resqlite_vector).

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `file_id` | TEXT NOT NULL UNIQUE | Reference to files table |
| `vector` | BLOB | Dense float vector (1536 or 2048 dims) |

**Query:**

```dart
// Find similar files by vector
final similar = await database.vectorSearch(
  'file_embeddings',
  'vector',
  queryVector,  // List<double>
  limit: 10,
);
```

### emails

Email messages from all providers (Gmail, Outlook, Yahoo).

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID or provider message ID |
| `provider` | TEXT | "gmail", "outlook", "yahoo" |
| `message_id` | TEXT UNIQUE | Provider's native message ID |
| `thread_id` | TEXT | Thread/conversation ID |
| `subject` | TEXT | Email subject |
| `from` | TEXT | Sender address |
| `to` | TEXT | Recipients (comma-separated or JSON) |
| `cc` | TEXT | CC recipients |
| `bcc` | TEXT | BCC recipients |
| `body` | TEXT | Plain text body |
| `html_body` | TEXT | HTML body |
| `received_at` | INTEGER | Received timestamp (seconds) |
| `folder_id` | TEXT | Folder reference |
| `is_flagged` | INTEGER DEFAULT 0 | Boolean (0/1) |
| `is_unread` | INTEGER DEFAULT 0 | Boolean (0/1) |
| `labels` | TEXT | Labels (Gmail) or JSON array |

**Indices:**

```sql
CREATE INDEX idx_emails_folder_id ON emails(folder_id);
CREATE INDEX idx_emails_received_at ON emails(received_at DESC);
CREATE INDEX idx_emails_provider ON emails(provider);
```

### email_embeddings

Vector embeddings for email semantic search.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `email_id` | TEXT NOT NULL UNIQUE | Reference to emails table |
| `vector` | BLOB | Dense float vector |

### albums

Photo albums for organization.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `name` | TEXT NOT NULL | Album name |
| `description` | TEXT | Album description |
| `cover_file_id` | TEXT | Thumbnail/cover photo ID |
| `created_at` | INTEGER NOT NULL | Created timestamp (seconds) |
| `updated_at` | INTEGER NOT NULL | Last modified timestamp (seconds) |

### album_files

Membership of files in albums (many-to-many).

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `album_id` | TEXT NOT NULL | Album reference |
| `file_id` | TEXT NOT NULL | File reference |
| `position` | INTEGER | Sort order within album |
| `added_at` | INTEGER | Added timestamp (seconds) |

**Unique Index:**

```sql
CREATE UNIQUE INDEX idx_album_files_unique ON album_files(album_id, file_id);
```

### file_tags

Flexible tagging system for files.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `file_id` | TEXT NOT NULL | File reference |
| `tag` | TEXT NOT NULL | Tag text |
| `created_at` | INTEGER | Created timestamp (seconds) |

**Unique Index:**

```sql
CREATE UNIQUE INDEX idx_file_tags_unique ON file_tags(file_id, tag);
```

### providers

OAuth credentials for cloud sources (encrypted).

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `name` | TEXT NOT NULL | "google_drive", "gmail", "yahoo", "outlook" |
| `user_id` | TEXT NOT NULL | User reference |
| `access_token` | TEXT | OAuth access token (encrypted) |
| `refresh_token` | TEXT | OAuth refresh token (encrypted) |
| `token_expiry` | INTEGER | Expiry timestamp (seconds) |
| `scope` | TEXT | OAuth scope |
| `created_at` | INTEGER | Created timestamp (seconds) |

**Security Note:** Tokens are encrypted at rest using AES. See `credential_codec.dart` for encryption/decryption.

### aichat_model

Available AI models.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `name` | TEXT NOT NULL | Model name (e.g., "gemma-4-12b") |
| `provider` | TEXT | "local", "google", "anthropic", "openai" |
| `type` | TEXT | "chat", "embedding" |
| `description` | TEXT | Model description |
| `is_installed` | INTEGER DEFAULT 0 | Downloaded locally (0/1) |
| `file_path` | TEXT | Path to GGUF file (local models only) |
| `model_size` | INTEGER | Size in bytes |

### aichat_conversation

Chat conversation history.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `title` | TEXT | Conversation title |
| `model_id` | TEXT | Selected model ID |
| `created_at` | INTEGER | Created timestamp (seconds) |
| `updated_at` | INTEGER | Last updated timestamp (seconds) |

### aichat_message

Individual chat messages.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `conversation_id` | TEXT NOT NULL | Conversation reference |
| `role` | TEXT NOT NULL | "user" or "assistant" |
| `content` | TEXT NOT NULL | Message text |
| `image_ids` | TEXT | Attached file IDs (JSON array) |
| `created_at` | INTEGER | Created timestamp (seconds) |

**Indices:**

```sql
CREATE INDEX idx_aichat_message_conversation_id ON aichat_message(conversation_id);
CREATE INDEX idx_aichat_message_created_at ON aichat_message(created_at DESC);
```

### aichat_skill

Built-in chat skills/commands.

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PRIMARY KEY | UUID |
| `name` | TEXT NOT NULL | Skill name (e.g., "search") |
| `description` | TEXT | What the skill does |
| `syntax` | TEXT | Usage syntax |
| `is_enabled` | INTEGER DEFAULT 1 | Boolean (0/1) |

---

## Query Patterns

### Find Files by Collection

```dart
final rows = await database.queryAll('''
  SELECT * FROM files
  WHERE collection_id = ?
  ORDER BY created_at DESC
''', [collectionId]);

final files = rows.map((row) => File.fromMap(row)).toList();
```

### Find Similar Files (Vector Search)

```dart
// First, get embedding for query file
final queryRow = await database.queryOne('''
  SELECT vector FROM file_embeddings WHERE file_id = ?
''', [queryFileId]);

final queryVector = queryRow['vector'] as List<double>;

// Search for similar
final similar = await database.vectorSearch(
  'file_embeddings',
  'vector',
  queryVector,
  limit: 10,
);

// Join back to file metadata
final fileIds = similar.map((row) => row['file_id']).toList();
final files = await database.queryAll('''
  SELECT * FROM files WHERE id IN (${List.filled(fileIds.length, '?').join(',')})
''', fileIds);
```

### Group Files by Date

```dart
final rows = await database.queryAll('''
  SELECT created_at, COUNT(*) as count
  FROM files
  WHERE collection_id = ?
  GROUP BY DATE(datetime(created_at, 'unixepoch'))
  ORDER BY created_at DESC
''', [collectionId]);

final grouped = <String, int>{};
for (final row in rows) {
  final date = DateTime.fromMillisecondsSinceEpoch(row['created_at'] * 1000)
    .toString()
    .split(' ')[0];
  grouped[date] = row['count'];
}
```

### Insert or Update File

```dart
await database.execute('''
  INSERT INTO files (id, name, path, collection_id, created_at)
  VALUES (?, ?, ?, ?, ?)
  ON CONFLICT(path) DO UPDATE SET
    name = excluded.name,
    size = excluded.size
''', [id, name, path, collectionId, now]);
```

### Transaction Example

```dart
await database.transaction(() async {
  // Insert file
  await database.execute(
    'INSERT INTO files (...) VALUES (...)',
    [...]
  );
  
  // Insert embedding
  await database.execute(
    'INSERT INTO file_embeddings (...) VALUES (...)',
    [...]
  );
  
  // If any query fails, both are rolled back
});
```

---

## Indices for Performance

Key indices are created in the schema DDL:

```sql
CREATE INDEX idx_files_collection_id ON files(collection_id);
CREATE INDEX idx_files_folder_id ON files(folder_id);
CREATE INDEX idx_files_mime_type ON files(mime_type);
CREATE INDEX idx_files_created_at ON files(created_at DESC);
CREATE INDEX idx_emails_folder_id ON emails(folder_id);
CREATE INDEX idx_emails_received_at ON emails(received_at DESC);
CREATE INDEX idx_emails_provider ON emails(provider);
CREATE INDEX idx_aichat_message_conversation_id ON aichat_message(conversation_id);
```

**When to Add Indices:**

- Columns frequently used in `WHERE` clauses
- Columns used in `ORDER BY` (especially descending sorts)
- Foreign key columns for joins
- Avoid over-indexing — each index slows writes

---

## Vector Storage (resqlite_vector)

resqlite_vector supports fast approximate nearest neighbor (ANN) search:

```dart
// Insert embedding
await database.execute('''
  INSERT INTO file_embeddings (id, file_id, vector)
  VALUES (?, ?, ?)
''', [id, fileId, embedding]);

// Vector search
final results = await database.vectorSearch(
  'file_embeddings',
  'vector',
  queryEmbedding,  // List<double>
  limit: 10,
);

// Results include similarity score
for (final result in results) {
  print('${result["file_id"]}: similarity ${result["distance"]}');
}
```

---

## Schema Changes Checklist

When modifying the schema:

1. **Update schema DDL** in `database_manager.dart` (the `schemaDDL` string)
2. **Increment version** (`PRAGMA user_version`)
3. **Add migration** in `_runMigrations()` method
4. **Update Dart model** (e.g., `models/tables/file.dart`)
5. **Update repository** methods that read/write the table
6. **Add tests** for migration and queries
7. **Test with existing data** — ensure migration is idempotent

Example migration:

```dart
// In database_manager.dart
const String schemaDDL = '''
  ...
  CREATE TABLE IF NOT EXISTS file_tags (
    id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL,
    tag TEXT NOT NULL,
    created_at INTEGER,
    UNIQUE(file_id, tag)
  );
  ...
''';

// In _runMigrations()
if (version < 3) {
  await database.execute(
    'CREATE TABLE IF NOT EXISTS file_tags (...)'
  );
  await _setPragmaUserVersion(database, 3);
}
```

---

## Next Steps

- See [Flutter Client](./flutter-client.md) for repository query patterns
- See [Modules](./modules.md) for module-specific data access
- See [Architecture](./architecture.md) for write relay and isolation patterns
