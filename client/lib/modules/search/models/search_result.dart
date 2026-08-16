import 'package:mydatastudio/modules/search/services/result_ranking.dart';

/// Which archive a result came from. Drives tile rendering and the facet
/// counts, and is the seam a future social-posts source plugs into.
enum SearchResultType { email, file }

/// One ranked hit, flattened out of whichever table produced it.
///
/// Deliberately not a `File` or an `Email`: results from different sources are
/// interleaved by rank in a single list, so they have to share a shape. Callers
/// that need the full record load it by [id] once the user picks a result.
/// Where in a document a hit came from, for the footnote under a result.
///
/// Both anchors are nullable and which one exists is decided by the format,
/// not by chance: PDFs carry pages and no headings, while `.doc`, `.xls` and
/// `.ppt` carry headings and no pages at all — a Word file has no pages until
/// something lays it out (search plan §18f). So this renders whichever
/// arrived, and a document that yielded neither still cites nothing rather
/// than citing "page null".
class ChunkCitation {
  /// Position in the document's chunk set — `file_chunks.chunk_index`.
  final int chunkIndex;

  /// 1-based page, for paginated formats only.
  final int? page;

  /// The heading trail the passage sits under, e.g. `Report > Findings`.
  final String? headingPath;

  const ChunkCitation({
    required this.chunkIndex,
    this.page,
    this.headingPath,
  });

  /// True when there is something worth showing a reader.
  bool get hasAnchor => page != null || (headingPath?.isNotEmpty ?? false);

  /// The footnote text, without the file name the caller already displays.
  ///
  /// Reads as "page 13" or "Report > Findings", and joins both when a format
  /// supplies both rather than silently preferring one.
  String? get label {
    final parts = [
      if (page != null) 'page $page',
      if (headingPath != null && headingPath!.isNotEmpty) headingPath!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  String toString() => 'ChunkCitation($chunkIndex, ${label ?? "no anchor"})';
}

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

  /// How much deliberate human investment this artifact represents, which
  /// multiplies the fused score. Computed where the row is read, because the
  /// signals it derives from (favourited, in an album, which scanner brought
  /// it in) are columns rather than anything recoverable later.
  final SourceTier tier;

  /// Which passage of a document matched, when one did.
  ///
  /// Null for photos, mail, and any file matched on its name rather than its
  /// contents. Present only when the hit actually came from a chunk, which is
  /// what keeps a footnote from appearing under a result it does not describe.
  final ChunkCitation? citation;

  /// The email this file arrived as an attachment of, if it did.
  ///
  /// 91% of this archive's documents are attachments (§18a), so a chunk hit
  /// that cannot point back at the message it came with is a dead end in the
  /// common case rather than the rare one.
  final String? parentEmailId;

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
    this.tier = SourceTier.correspondence,
    this.citation,
    this.parentEmailId,
  });

  bool get isEmail => type == SearchResultType.email;
  bool get isFile => type == SearchResultType.file;

  /// Identity across both archives. Fusion ranks mail and files in one list,
  /// so an id alone is not enough to key on.
  String get key => '${type.name}:$id';

  /// The kind of thing this is, in the vocabulary a query uses when it names
  /// one ("photos", "emails"). Matches the values `type:` accepts, so a stated
  /// preference and a result can be compared without a translation table.
  ///
  /// `application/image` is not a typo — it is what this archive's scanners
  /// actually wrote for most of its 2,411 pictures, and a check for `image/`
  /// alone would miss almost every photo in it.
  String get modality {
    if (isEmail) return 'email';
    final mime = contentType?.toLowerCase() ?? '';
    if (mime.startsWith('image/') || mime == 'application/image') {
      return 'image';
    }
    if (mime.startsWith('video/') || mime == 'application/video') {
      return 'video';
    }
    if (mime.contains('pdf')) return 'pdf';
    return 'file';
  }

  /// This result with [score] replaced — used when fusion recomputes ranking.
  SearchResult withScore(double newScore) {
    return SearchResult(
      id: id,
      type: type,
      title: title,
      score: newScore,
      subtitle: subtitle,
      snippet: snippet,
      date: date,
      collectionId: collectionId,
      contentType: contentType,
      thumbnail: thumbnail,
      tier: tier,
      citation: citation,
      parentEmailId: parentEmailId,
    );
  }

  /// This result with [citation] attached — used when the vector pass, not the
  /// lexical one, is what identified the winning passage.
  SearchResult withCitation(ChunkCitation? newCitation) {
    if (newCitation == null) return this;
    return SearchResult(
      id: id,
      type: type,
      title: title,
      score: score,
      subtitle: subtitle,
      snippet: snippet,
      date: date,
      collectionId: collectionId,
      contentType: contentType,
      thumbnail: thumbnail,
      tier: tier,
      citation: newCitation,
      parentEmailId: parentEmailId,
    );
  }

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

  /// Which single archive [results] was restricted to, or null for everything.
  ///
  /// Kept because the totals above are deliberately *unrestricted* — the facet
  /// bar must keep showing every archive's count while one is selected. That
  /// makes an untouched cursor for an unfetched source look like pending work,
  /// so [hasMore] needs to know which sources are actually in play.
  final SearchResultType? sourceFilter;

  /// Fused results already retrieved and ranked but not yet published.
  ///
  /// Fusion has to rank a whole window at once — a reciprocal-rank score is
  /// meaningless without the other retriever's list — so a fused search fetches
  /// far more than it shows and pages through the ranking in memory. The
  /// per-source cursors below cannot express that: they track rows consumed
  /// from SQL, which for a fused head runs ahead of what the user has seen.
  final int rankedRemaining;

  /// How many of [emailTotal]/[fileTotal] the semantic pass contributed and no
  /// keyword matched.
  ///
  /// Counted *inside* the totals — they are what the user is told — but held
  /// separately because the per-source cursors track rows consumed from the
  /// FTS index, and no amount of paging that index will ever reach a row it
  /// does not match. Without subtracting these, [hasMore] stays true forever
  /// and the list asks for pages that cannot exist.
  final int emailSemanticOnly;
  final int fileSemanticOnly;

  const SearchResults({
    required this.results,
    this.emailTotal = 0,
    this.fileTotal = 0,
    this.emailOffset = 0,
    this.fileOffset = 0,
    this.sourceFilter,
    this.rankedRemaining = 0,
    this.emailSemanticOnly = 0,
    this.fileSemanticOnly = 0,
  });

  static const empty = SearchResults(results: []);

  /// Matches across every archive — the "All" count.
  int get total => emailTotal + fileTotal;

  /// Matches within the currently selected facet.
  int get totalInScope {
    switch (sourceFilter) {
      case SearchResultType.email:
        return emailTotal;
      case SearchResultType.file:
        return fileTotal;
      case null:
        return total;
    }
  }

  /// How many are currently loaded. An implementation detail, not something
  /// to put in front of the user.
  int get loadedCount => results.length;

  /// Whether another page remains to fetch, considering only sources being
  /// retrieved.
  bool get hasMore {
    if (rankedRemaining > 0) return true;
    final emailPending =
        sourceFilter != SearchResultType.file &&
        emailOffset < emailTotal - emailSemanticOnly;
    final filePending =
        sourceFilter != SearchResultType.email &&
        fileOffset < fileTotal - fileSemanticOnly;
    return emailPending || filePending;
  }

  bool get isEmpty => results.isEmpty;

  /// This set with [page] appended and its cursors advanced.
  SearchResults append(SearchResults page) {
    return SearchResults(
      results: [...results, ...page.results],
      emailTotal: page.emailTotal,
      fileTotal: page.fileTotal,
      emailOffset: page.emailOffset,
      fileOffset: page.fileOffset,
      sourceFilter: page.sourceFilter,
      rankedRemaining: page.rankedRemaining,
      emailSemanticOnly: page.emailSemanticOnly,
      fileSemanticOnly: page.fileSemanticOnly,
    );
  }
}
