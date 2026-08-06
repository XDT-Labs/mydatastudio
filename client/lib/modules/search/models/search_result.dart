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
/// The loaded page(s) of a search plus the counts describing the whole match
/// set behind them.
///
/// Every count here is a **corpus total**, not a count of what is loaded. With
/// infinite scroll every match is reachable, so a facet reading "Photos & Files
/// 500" beside a set of 1,134 would be understating the archive to describe an
/// implementation detail. The user asked how many matches exist; that is the
/// number to show.
class SearchResults {
  /// Every result loaded so far — grows as further pages are appended.
  final List<SearchResult> results;

  /// Matches across the whole archive, ignoring pagination. Computed by their
  /// own `COUNT(*)` rather than inferred from [results], because a source that
  /// filled its page is indistinguishable from one that happened to return
  /// exactly that many rows.
  final int emailTotal;
  final int fileTotal;

  /// How many rows of each source have been consumed — the cursor the next
  /// page resumes from.
  ///
  /// Per-source rather than one global offset because the two sources are
  /// ranked independently and merged. Having taken the best `emailOffset`
  /// emails and best `fileOffset` files, the next best overall results are
  /// exactly what follows each of those cursors.
  final int emailOffset;
  final int fileOffset;

  const SearchResults({
    required this.results,
    this.emailTotal = 0,
    this.fileTotal = 0,
    this.emailOffset = 0,
    this.fileOffset = 0,
  });

  static const empty = SearchResults(results: []);

  /// Total matches in the archive — what every count in the UI reports.
  int get total => emailTotal + fileTotal;

  /// How many are currently loaded. An implementation detail, not something
  /// to put in front of the user.
  int get loadedCount => results.length;

  /// Whether another page remains to fetch.
  bool get hasMore => emailOffset < emailTotal || fileOffset < fileTotal;

  bool get isEmpty => results.isEmpty;

  /// This set with [page] appended and its cursors advanced.
  SearchResults append(SearchResults page) {
    return SearchResults(
      results: [...results, ...page.results],
      emailTotal: page.emailTotal,
      fileTotal: page.fileTotal,
      emailOffset: page.emailOffset,
      fileOffset: page.fileOffset,
    );
  }
}
