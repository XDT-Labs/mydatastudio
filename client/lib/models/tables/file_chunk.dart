/// One extracted passage of a document, and where in the document it came from.
///
/// Rows in `file_chunks` pair one-to-one with `type='chunk'` rows in
/// `files_embeddings`: `(file_id, chunk_index)` here is `(file_id, sequence)`
/// there. The vector answers *which* passage matched; this answers *where it
/// is*, which is what a search result footnote renders (search plan §18e/§18f).
///
/// [page] and [headingPath] are complementary rather than alternatives, and
/// neither is reliably present. PDFs carry pages and no headings; `.doc`,
/// `.xls` and `.ppt` carry headings and no pages at all — a Word file has no
/// pages until something lays it out. A footnote renders whichever arrived.
///
/// Crosses an isolate port, so it also carries [toPortMap]/[fromPortMap]. Those
/// are separate from the database mapping on purpose: the port shape is the
/// extractor's vocabulary and the database shape is the schema's, and letting
/// one rename force the other is how they drift.
class FileChunk {
  final int chunkIndex;
  final String text;
  final int? page;
  final String? headingPath;
  final int? charStart;
  final int? charEnd;

  const FileChunk({
    required this.chunkIndex,
    required this.text,
    this.page,
    this.headingPath,
    this.charStart,
    this.charEnd,
  });

  factory FileChunk.fromDbMap(Map<String, dynamic> map) => FileChunk(
    chunkIndex: map['chunk_index'] as int,
    text: map['text'] as String,
    page: map['page'] as int?,
    headingPath: map['heading_path'] as String?,
    charStart: map['char_start'] as int?,
    charEnd: map['char_end'] as int?,
  );

  Map<String, dynamic> toDbMap() => {
    'chunk_index': chunkIndex,
    'text': text,
    'page': page,
    'heading_path': headingPath,
    'char_start': charStart,
    'char_end': charEnd,
  };

  /// The shape `/util/extract-text` returns, which is also what travels over
  /// the isolate's control port.
  factory FileChunk.fromPortMap(Map<dynamic, dynamic> map) => FileChunk(
    chunkIndex: map['chunk_index'] as int,
    text: map['text'] as String? ?? '',
    page: map['page'] as int?,
    headingPath: map['heading_path'] as String?,
    charStart: map['char_start'] as int?,
    charEnd: map['char_end'] as int?,
  );

  Map<String, Object?> toPortMap() => {
    'chunk_index': chunkIndex,
    'text': text,
    'page': page,
    'heading_path': headingPath,
    'char_start': charStart,
    'char_end': charEnd,
  };
}
