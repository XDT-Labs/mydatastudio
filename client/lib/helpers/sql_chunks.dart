/// Splits [ids] into batches small enough to bind as `IN (?, ?, …)`.
///
/// The bundled SQLite refuses a statement carrying more than
/// `SQLITE_MAX_VARIABLE_NUMBER` bound parameters — 32766 — so any query that
/// expands an unbounded id list into placeholders has a hard ceiling. That is
/// reachable in practice: a folder resync that finds tens of thousands of
/// messages gone from the server hands the whole set to one delete.
///
/// [size] is well under the limit rather than at it, because a statement with
/// thirty thousand parameters is slow to prepare even when it is legal.
Iterable<List<T>> sqlChunks<T>(List<T> ids, {int size = 500}) sync* {
  for (var start = 0; start < ids.length; start += size) {
    final end = start + size;
    yield ids.sublist(start, end > ids.length ? ids.length : end);
  }
}
