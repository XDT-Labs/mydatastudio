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
  static const modelName = 'google/embeddinggemma-2';

  /// Output dimensionality of [modelName] embeddings (768-d L2-normalized).
  ///
  /// Single source of truth for vector dimensions across the client.
  static const dimension = 768;

  /// Bumped whenever stored vectors stop being comparable with new ones.
  ///
  /// The model name alone is not enough — changes in pooling, prompt templates,
  /// or checkpoint loading alter what vectors mean even under the same model.
  /// Anything that alters the output space belongs here.
  ///
  /// Revision restarts at 1 because the underlying model changed from Qwen
  /// to EmbeddingGemma 2 (`google/embeddinggemma-2`).
  ///
  /// Historical revisions for `google/embeddinggemma-2`:
  /// - `1` — initial migration to EmbeddingGemma 2 (768-d L2-normalized vectors
  ///   supporting text, image, audio, video).
  ///
  /// Older revisions under legacy `Qwen/Qwen3-VL-Embedding-2B`:
  /// - `1` — original; `AutoModel` silently discarded the language model and
  ///   replaced it with random weights. Every such vector was noise.
  /// - `2` — loaded via the checkpoint's declared class, raising rather than
  ///   serving noise if any tensor came back randomly initialised.
  static const revision = 1;

  /// What lands in the `model_version` column.
  static const current = '$modelName@$revision';
}
