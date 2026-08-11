/// Identifies which embedding pipeline produced a stored vector.
///
/// Vectors are only comparable to other vectors built the same way. Nothing
/// downstream can detect otherwise: cosine similarity over two incompatible
/// spaces returns confident, plausible-looking numbers, and a search ranked by
/// them looks like a working search with poor recall.
///
/// This is not hypothetical. Every vector written before the loader fix in
/// `aiserver` came from a randomly-initialised model — noise, and *differently*
/// noisy on each process launch — and nothing in the app could tell. The
/// embedding isolates only ever fill rows where the vector `IS NULL`, so a
/// populated row was never revisited and the archive would have stayed broken
/// until someone deleted 6,000 rows by hand.
///
/// Stamping the version onto every row makes that self-healing: bump
/// [current], and rows written by anything else become work the isolates pick
/// up on their own.
class EmbeddingModel {
  /// The model every embedding in this app is computed with.
  static const modelName = 'Qwen/Qwen3-VL-Embedding-2B';

  /// Bumped whenever stored vectors stop being comparable with new ones.
  ///
  /// The model name alone is not enough — the loader bug changed what the
  /// vectors *meant* without changing which model produced them. Anything that
  /// alters the output space belongs here: a different checkpoint, different
  /// pooling, a different prompt template, or a fix like that one.
  ///
  /// - `1` — original; `AutoModel` silently discarded the language model and
  ///   replaced it with random weights. Every such vector is noise.
  /// - `2` — loads via the checkpoint's declared class, and raises rather than
  ///   serving noise if any tensor comes back randomly initialised.
  static const revision = 2;

  /// What lands in the `model_version` column.
  static const current = '$modelName@$revision';
}
