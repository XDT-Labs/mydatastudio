/// Which archive a result came from. Drives tile rendering and the facet
/// counts, and is the seam a future social-posts source plugs into.
enum SearchResultType { email, file }

/// One ranked hit, flattened out of whichever table produced it.
///
/// Deliberately not a `File` or an `Email`: results from different sources are
/// interleaved by rank in a single list, so they have to share a shape. Callers
/// that need the full record load it by [id] once the user picks a result.
class SearchResult {
  final String id;
  final SearchResultType type;

  /// Subject line for mail, file name for a file.
  final String title;

  /// Sender for mail, path for a file — the line under the title.
  final String? subtitle;

  /// Why this matched, when there is something worth showing: an AI
  /// description or message snippet. Roughly a third of hits come from a
  /// vector or a description rather than the visible title, and without a
  /// reason the result reads as arbitrary.
  final String? snippet;

  final DateTime? date;

  /// Higher is better.
  ///
  /// FTS5's `bm25()` returns *negative* values where more-negative means more
  /// relevant. That sign is flipped here, at the boundary, so no downstream
  /// ranking, fusion or UI code has to remember it — getting it backwards
  /// sorts the worst matches to the top and still looks plausible.
  final double score;

  final String? collectionId;

  /// MIME type, for files only — lets the UI pick an icon without a second
  /// query.
  final String? contentType;

  final String? thumbnail;

  const SearchResult({
    required this.id,
    required this.type,
    required this.title,
    required this.score,
    this.subtitle,
    this.snippet,
    this.date,
    this.collectionId,
    this.contentType,
    this.thumbnail,
  });

  bool get isEmail => type == SearchResultType.email;
  bool get isFile => type == SearchResultType.file;

  @override
  String toString() =>
      'SearchResult(${type.name}, $id, "${title.length > 40 ? '${title.substring(0, 40)}…' : title}", ${score.toStringAsFixed(3)})';
}

/// A full result set plus the counts the facet sidebar needs.
///
/// Counts come from the same query as the results rather than a second pass,
/// so "Emails 112" can never disagree with what scrolling actually shows.
class SearchResults {
  final List<SearchResult> results;
  final int emailCount;
  final int fileCount;

  /// True when the ranked list was cut off by a limit. The UI has to say so:
  /// a user reading a truncated set as complete is the failure mode behind
  /// "summarise all of my mail from X" quietly summarising fifty messages.
  final bool truncated;

  const SearchResults({
    required this.results,
    required this.emailCount,
    required this.fileCount,
    this.truncated = false,
  });

  static const empty = SearchResults(
    results: [],
    emailCount: 0,
    fileCount: 0,
  );

  int get total => results.length;
  bool get isEmpty => results.isEmpty;
}
