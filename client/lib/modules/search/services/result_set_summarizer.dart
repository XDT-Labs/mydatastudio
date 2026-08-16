import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/email/services/searchable_body.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/repositories/aichat_repository.dart';

/// Whether a summary describes the whole match set or a slice of it.
///
/// This is the distinction §2e exists for, and it is the reason this file
/// carries as much accounting as it does. Summarizing a top-50 sample while
/// the user reads the answer as "all of them" is the worst outcome available
/// here — a confidently incomplete answer with nothing to signal that anything
/// was left out.
enum SummaryCoverage {
  /// Every matching item was read. The denominator is known and was reached.
  complete,

  /// A ranked slice. There are matches this summary did not see.
  sample,
}

/// One step of a running summarization, for a progress indicator.
class SummarizeProgress {
  const SummarizeProgress({
    required this.itemsRead,
    required this.itemsTotal,
    required this.stage,
  });

  final int itemsRead;
  final int itemsTotal;

  /// Human-readable phase: which batch is being condensed, or the final merge.
  final String stage;
}

/// A finished summary and an honest description of what it covered.
class ResultSetSummary {
  const ResultSetSummary({
    required this.text,
    required this.coverage,
    required this.itemsSummarized,
    required this.matchTotal,
    required this.batches,
    this.parts = const [],
    this.sources = const [],
  });

  final String text;
  final SummaryCoverage coverage;

  /// The source material itself, one rendered entry per result.
  ///
  /// A summary answers "what was this about"; it cannot answer "what was the
  /// technical question, and what was the answer" — reducing threw that away,
  /// which is what reducing is. When the set is small enough to fit a context
  /// window there is no reason to make the model work from the compressed
  /// version, so the handoff carries these instead.
  final List<String> sources;

  /// The per-batch condensations [text] was reduced from.
  ///
  /// Kept because reducing is lossy by construction: the final summary is the
  /// answer, and these are the layer that still holds the names, dates and
  /// specifics it dropped. The chat handoff carries them so a follow-up
  /// question can reach detail the summary itself no longer contains.
  final List<String> parts;

  /// How many items were actually read and fed to the model.
  final int itemsSummarized;

  /// How many matches exist. Exact for [SummaryCoverage.complete]; for a
  /// sample it is the lexical count plus whatever the semantic pass added, so
  /// it is approximate and is reported as such.
  final int matchTotal;

  final int batches;

  /// The sentence shown above the summary. Never says "all" unless it is.
  String get coverageStatement =>
      coverage == SummaryCoverage.complete
          ? 'Summarized all $matchTotal ${_noun(matchTotal)}.'
          : 'Summarized the $itemsSummarized most relevant of about '
              '$matchTotal ${_noun(matchTotal)}.';

  static String _noun(int n) => n == 1 ? 'result' : 'results';
}

/// Why a summarization produced nothing.
///
/// It exists because the first version reported every failure as "the AI
/// service may not be running", and the first real failure in the wild was a
/// batch timeout against a service that was running fine — the message sent
/// the reader looking in exactly the wrong place.
enum SummarizeFailure {
  /// The query matched nothing to summarize.
  noResults,

  /// No service URL yet, or the request never reached one.
  serviceUnavailable,

  /// A batch was still generating when the per-call timeout expired.
  timedOut,

  /// The service answered, and the answer was an error or was empty.
  modelError,
}

/// Issues one non-streaming chat completion and returns the assistant text.
///
/// A seam rather than a hard dependency so the map-reduce can be tested
/// without an LLM: the batching, the ordering and the coverage arithmetic are
/// the parts that can be wrong in ways nobody would notice.
typedef ChatCompletion = Future<String?> Function(String prompt);

/// The shape of [ResultSetSummarizer.summarize], so a caller can hold the
/// operation without holding a database to build one from.
typedef SummarizeRunner =
    Future<ResultSetSummary?> Function(
      ParsedQuery query, {
      int semanticOnly,
      List<SearchResult> retrieved,
      void Function(SummarizeProgress)? onProgress,
    });

/// Summarizes a whole result set by map-reduce rather than by truncation.
///
/// The problem this solves is stated in §2e: "summarize all of my interactions
/// with Russel Jong" is a **completeness** claim, and 412 messages do not fit a
/// local model's context. Feeding it the top 50 produces a fluent answer that
/// is silently wrong about its own scope. So the set is read in batches, each
/// batch is condensed, and the condensations are summarized in turn.
///
/// Retrieval here goes through [Bm25Retriever] alone, deliberately. Its totals
/// are `COUNT(*)` over the hard filters, and every counted row is reachable by
/// paging — which is exactly what makes "all 412" sayable. The vector path
/// cannot make that claim at any size: it returns a top-K, so there is no
/// denominator to be complete against. When the caller's search did draw on
/// vectors it says so through [semanticOnly], and the result is reported as a
/// sample.
class ResultSetSummarizer {
  ResultSetSummarizer({
    required this.db,
    ChatCompletion? complete,
    Bm25Retriever? lexical,
  }) : lexical = lexical ?? Bm25Retriever(db) {
    // Bound here rather than passed as a bare function reference so the default
    // path can report *why* it gave up. An injected [complete] leaves
    // [lastFailure] null, and the caller falls back to a generic message.
    this.complete =
        complete ?? (prompt) => _aiServerCompletion(prompt, _recordFailure);
  }

  final AppDatabase db;
  final Bm25Retriever lexical;
  late final ChatCompletion complete;

  /// Why the most recent [summarize] returned null.
  ///
  /// Mutable state on a service, which is normally worth avoiding — it is
  /// tolerable here because an instance serves one dialog and one run, and the
  /// alternative was threading a result type through every call site to carry
  /// one enum.
  SummarizeFailure? lastFailure;

  void _recordFailure(SummarizeFailure failure) => lastFailure = failure;

  static final AppLogger _logger = AppLogger(null);

  /// Items condensed per map call.
  ///
  /// Sized against the batch's character budget rather than by taste: 25 items
  /// at [_charsPerItem] is roughly 20k characters of prompt, comfortably inside
  /// a local model's window with room for the instruction and the reply.
  static const batchSize = 25;

  /// Body characters kept per item inside a batch.
  ///
  /// A whole 60k-character thread would push everything else out of the batch,
  /// and the tail of a long message is mostly quoted history the earlier
  /// messages in the same set already cover.
  static const _charsPerItem = 1200;

  /// Hard ceiling on items read, whatever the match count says.
  ///
  /// This is what makes the coverage flag load-bearing rather than decorative:
  /// past this, a set that *was* countable stops being completely read, and
  /// [SummaryCoverage.sample] is what says so. Without a ceiling, "summarize
  /// everything" over a 200k-message archive is an hours-long operation
  /// started by one click.
  static const maxItems = 1000;

  /// Characters a single batch condensation may contribute.
  ///
  /// Measured, not guessed. Without a stated budget the model answered a
  /// 25-message batch with 6,281 characters — roughly 1,570 generated tokens,
  /// which at ~12 tok/s on a local 12B is where the 2m14s per batch came from.
  /// Generation dominates the cost here, so the length of the reply *is* the
  /// speed of the feature.
  ///
  /// It is also what keeps the reduce feasible: 17 batches at the old length
  /// is 107k characters of prompt against a 32,768-token window. Both problems
  /// have the same cause and the same fix.
  static const maxCondensationChars = 2400;

  /// Characters a reduce prompt may reach before it is split.
  ///
  /// The window is 32,768 tokens (`model_manager.py`), so ~130k characters
  /// including the reply. 40k leaves generous room and still fits 16 batches
  /// in one pass; past that the reduce recurses rather than overflowing.
  static const maxReducePromptChars = 40000;

  /// Source characters that still fit a single summarization prompt.
  ///
  /// Below this the whole map-reduce is skipped and the model summarizes the
  /// results directly, in one pass. Batching exists because 412 messages do
  /// not fit a context window — it is not a virtue in itself, and running it
  /// over 18 emails that would have fit costs an extra call and reasons from
  /// a lossy intermediate instead of from the text.
  ///
  /// 60,000 characters against a 32,768-token window (~130k characters) leaves
  /// generous room for the instruction and a long reply.
  static const maxSinglePassChars = 60000;

  /// Characters the final summary may run to.
  ///
  /// Larger than [maxCondensationChars] because this is the answer rather than
  /// an intermediate, but still bounded: generation time is roughly the length
  /// of the reply, and nobody reads twenty thousand characters of summary.
  static const maxSummaryChars = 4000;

  /// How long one batch may take before it is abandoned.
  ///
  /// Ten minutes, not five. A budgeted batch of 25 measures ~71s on a local
  /// 12B, so this is roughly 8x headroom — but the first real failure in the
  /// wild was batch 4 of 4 hitting a 5-minute ceiling while the file-embedding
  /// isolate was competing for the same GPU, and giving up there discarded
  /// everything the three completed batches had cost. The timeout's job is to
  /// catch a wedged subprocess, not a busy one.
  static const perCallTimeout = Duration(minutes: 10);

  /// Reads the whole set (up to [maxItems]) and summarizes it.
  ///
  /// [semanticOnly] is how many of the caller's on-screen results came from a
  /// vector and no keyword — [SearchResults.emailSemanticOnly] plus
  /// [SearchResults.fileSemanticOnly]. Anything above zero means the set the
  /// user is looking at is a ranked one, and no amount of paging this
  /// retriever would reproduce it.
  Future<ResultSetSummary?> summarize(
    ParsedQuery query, {
    int semanticOnly = 0,
    List<SearchResult> retrieved = const [],
    void Function(SummarizeProgress)? onProgress,
  }) async {
    final items = <_SummaryItem>[];
    final seen = <String>{};
    var emailOffset = 0;
    var fileOffset = 0;
    var matchTotal = 0;

    // Page until the retriever runs dry or the ceiling is hit. `hasMore` is not
    // consulted: it answers a UI question about unshown rows, whereas the only
    // thing that ends this loop is a page that added nothing.
    while (items.length < maxItems) {
      final page = await lexical.search(
        query,
        emailOffset: emailOffset,
        fileOffset: fileOffset,
      );
      matchTotal = page.emailTotal + page.fileTotal;
      if (page.results.isEmpty) break;

      items.addAll(await _load(page.results));
      seen.addAll(page.results.map((r) => r.key));
      emailOffset = page.emailOffset;
      fileOffset = page.fileOffset;
      onProgress?.call(
        SummarizeProgress(
          itemsRead: items.length,
          itemsTotal: matchTotal,
          stage: 'Reading results',
        ),
      );
    }

    // Everything on screen is summarized, whether this retriever could reach
    // it or not.
    //
    // The button says "summarize these results", and the set the user is
    // looking at is what "these" means. Lexical paging alone is a *different*
    // set whenever free text is involved: the count is `FTS MATCH ? AND
    // filter`, so a fused search showing 18 emails can leave this retriever
    // holding the 3 that happen to contain the query's words. Summarizing
    // those 3 and calling it "all 3" was true about the wrong set.
    final fromScreen = <SearchResult>[
      for (final r in retrieved)
        if (!seen.contains(r.key)) r,
    ];
    if (fromScreen.isNotEmpty) {
      items.addAll(await _load(fromScreen.take(maxItems - items.length).toList()));
    }

    if (items.isEmpty) {
      lastFailure = SummarizeFailure.noResults;
      return null;
    }
    final read = items.take(maxItems).toList();
    final sources = [
      for (var i = 0; i < read.length; i++)
        read[i].render(i + 1, SummaryChatHandoff.sourceCharsPerItem),
    ];

    // Anything the lexical pass could not reach is anything paging cannot
    // enumerate, so the denominator is gone and completeness with it.
    final coverage =
        read.length >= matchTotal && semanticOnly == 0 && fromScreen.isEmpty
            ? SummaryCoverage.complete
            : SummaryCoverage.sample;
    if (fromScreen.isNotEmpty) {
      matchTotal = matchTotal > read.length ? matchTotal : read.length;
    }

    // One prompt when one prompt is enough.
    //
    // Map-reduce is a workaround for a context window, not an improvement on
    // reading the text. When the whole set fits, summarizing it directly costs
    // one call instead of two and reasons from the messages rather than from a
    // condensation of them.
    final sourceChars = sources.fold<int>(0, (sum, s) => sum + s.length);
    if (sourceChars <= maxSinglePassChars) {
      onProgress?.call(
        SummarizeProgress(
          itemsRead: read.length,
          itemsTotal: matchTotal,
          stage: 'Summarizing ${read.length} results',
        ),
      );
      final reply = await complete(_singlePassPrompt(query, sources));
      if (reply == null || reply.trim().isEmpty) {
        _logger.w('Summarize: single-pass summary returned nothing');
        return null;
      }
      return ResultSetSummary(
        text: _clip(reply.trim(), maxSummaryChars),
        coverage: coverage,
        itemsSummarized: read.length,
        matchTotal: matchTotal,
        batches: 1,
        sources: sources,
      );
    }

    final batches = <List<_SummaryItem>>[
      for (var i = 0; i < read.length; i += batchSize)
        read.sublist(i, i + batchSize > read.length ? read.length : i + batchSize),
    ];

    final condensed = <String>[];
    for (var i = 0; i < batches.length; i++) {
      onProgress?.call(
        SummarizeProgress(
          itemsRead: read.length,
          itemsTotal: matchTotal,
          stage: 'Condensing batch ${i + 1} of ${batches.length}',
        ),
      );
      final reply = await complete(_mapPrompt(query, batches[i], i, batches.length));
      // One failed batch must not be silently folded into the answer as if it
      // had contributed — it downgrades the claim instead.
      if (reply == null || reply.trim().isEmpty) {
        _logger.w('Summarize: batch ${i + 1} of ${batches.length} returned nothing');
        return _partial(condensed, query, read, matchTotal, batches.length);
      }
      // Trimmed rather than trusted. The budget is stated in the prompt, but a
      // model that ignores it would put the reduce back over the window, and
      // the tail of an over-long condensation is the least informative part
      // of it.
      condensed.add(_clip(reply.trim(), maxCondensationChars));
    }

    if (condensed.length == 1) {
      return ResultSetSummary(
        text: condensed.single,
        coverage: coverage,
        itemsSummarized: read.length,
        matchTotal: matchTotal,
        batches: 1,
        parts: condensed,
        sources: sources,
      );
    }

    final reduced = await _reduce(
      query,
      condensed,
      read.length,
      matchTotal,
      onProgress,
    );
    if (reduced == null) {
      return _partial(condensed, query, read, matchTotal, batches.length);
    }

    return ResultSetSummary(
      text: reduced,
      coverage: coverage,
      itemsSummarized: read.length,
      matchTotal: matchTotal,
      batches: batches.length,
      parts: condensed,
      sources: sources,
    );
  }

  /// Merges the batch summaries, recursing when they will not fit one prompt.
  ///
  /// Dropping parts to fit would be the easier implementation and the wrong
  /// one: it silently removes messages from a summary whose whole claim is
  /// that it covered them. Merging in groups and re-merging the results costs
  /// extra passes and keeps every batch represented, which is the property
  /// this class exists to hold.
  Future<String?> _reduce(
    ParsedQuery query,
    List<String> parts,
    int items,
    int matchTotal,
    void Function(SummarizeProgress)? onProgress,
  ) async {
    var current = parts;
    var round = 1;

    while (current.length > 1) {
      final groups = groupByPromptBudget(
        [for (final p in current) p.length],
        maxReducePromptChars,
      );
      onProgress?.call(
        SummarizeProgress(
          itemsRead: items,
          itemsTotal: matchTotal,
          stage:
              groups.length == 1
                  ? 'Combining ${current.length} batch summaries'
                  : 'Combining ${current.length} batch summaries '
                      '(pass $round, ${groups.length} groups)',
        ),
      );

      final merged = <String>[];
      for (final group in groups) {
        final slice = [for (final i in group) current[i]];
        final reply = await complete(_reducePrompt(query, slice, items));
        if (reply == null || reply.trim().isEmpty) return null;
        merged.add(_clip(reply.trim(), maxCondensationChars));
      }

      // A group that could not be split further would loop forever. It cannot
      // happen — groupByPromptBudget always emits an oversized part alone, so
      // a single group of one is the terminating case — but the guard is
      // cheaper than the hang it prevents.
      if (merged.length >= current.length) return merged.first;
      current = merged;
      round++;
    }
    return current.single;
  }

  /// Packs part indices into groups no larger than [budget] characters.
  ///
  /// A part longer than the budget travels alone rather than being split: the
  /// parts are summaries, and half a summary merged with someone else's half
  /// is worse than one oversized prompt the model will truncate at the end.
  @visibleForTesting
  static List<List<int>> groupByPromptBudget(List<int> sizes, int budget) {
    final groups = <List<int>>[];
    var current = <int>[];
    var used = 0;
    for (var i = 0; i < sizes.length; i++) {
      if (current.isNotEmpty && used + sizes[i] > budget) {
        groups.add(current);
        current = <int>[];
        used = 0;
      }
      current.add(i);
      used += sizes[i];
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  static String _clip(String text, int limit) =>
      text.length <= limit ? text : '${text.substring(0, limit)}…';

  /// What to return when the model stopped part-way.
  ///
  /// The batch summaries already produced are worth keeping, but the claim
  /// attached to them is not: a set read completely and then summarized
  /// incompletely is still an incomplete answer, so this is always a sample.
  ResultSetSummary? _partial(
    List<String> condensed,
    ParsedQuery query,
    List<_SummaryItem> read,
    int matchTotal,
    int batches,
  ) {
    if (condensed.isEmpty) return null;
    final covered = condensed.length * batchSize;
    return ResultSetSummary(
      text: condensed.join('\n\n'),
      coverage: SummaryCoverage.sample,
      itemsSummarized: covered > read.length ? read.length : covered,
      matchTotal: matchTotal,
      batches: batches,
    );
  }

  /// Loads the text each result contributes.
  ///
  /// Mail reads `body_text` — the stored output of [bodyTextFrom], which is
  /// also what the FTS index and the embedding producer read — so a summary
  /// can never be built from markup the search that found it never saw. The
  /// live fallback is for rows the backfill has not reached, where the column
  /// is still null. Files have no body: their AI description is already on the
  /// result as the snippet.
  Future<List<_SummaryItem>> _load(List<SearchResult> results) async {
    final emailIds = [for (final r in results) if (r.isEmail) r.id];
    final bodies = <String, String>{};
    for (var i = 0; i < emailIds.length; i += 200) {
      final batch = emailIds.sublist(
        i,
        i + 200 > emailIds.length ? emailIds.length : i + 200,
      );
      final rows = await db.select(
        'SELECT id, html_body, plain_body, body_text FROM emails '
        'WHERE id IN (${List.filled(batch.length, '?').join(',')})',
        batch,
      );
      for (final row in rows) {
        final stored = (row['body_text'] as String?)?.trim() ?? '';
        bodies[row['id'] as String] =
            stored.isNotEmpty
                ? stored
                : bodyTextFrom(
                  row['plain_body'] as String?,
                  row['html_body'] as String?,
                );
      }
    }

    return [
      for (final r in results)
        _SummaryItem(
          title: r.title,
          subtitle: r.subtitle,
          date: r.date,
          body: r.isEmail ? (bodies[r.id] ?? '') : (r.snippet ?? ''),
        ),
    ];
  }

  /// The whole set in one prompt, summarized directly.
  ///
  /// Deliberately not the map prompt with a different count. A condensation is
  /// an intermediate that must not draw conclusions, because it will be merged
  /// with others; this is the answer the user reads, so it is allowed to say
  /// what the results add up to.
  String _singlePassPrompt(ParsedQuery query, List<String> sources) {
    final buffer = StringBuffer()
      ..writeln(
        'These are all ${sources.length} results from a personal archive '
        'matching: "${query.raw}".',
      )
      ..writeln()
      ..writeln(
        'Summarize them: what was discussed, with whom, and when. Group '
        'related items, keep names and dates, and note anything that recurs '
        'across several of them. Use only what is in the text below.',
      )
      ..writeln('Keep the reply under $maxSummaryChars characters.')
      ..writeln();
    for (final source in sources) {
      buffer.writeln(source);
    }
    return buffer.toString();
  }

  String _mapPrompt(
    ParsedQuery query,
    List<_SummaryItem> batch,
    int index,
    int of,
  ) {
    final buffer = StringBuffer()
      ..writeln(
        'These are results ${index * batchSize + 1}-'
        '${index * batchSize + batch.length} of a larger set from a personal '
        'archive, matching: "${query.raw}".',
      )
      ..writeln()
      ..writeln(
        'Condense them into factual bullet points: who was involved, what was '
        'discussed or decided, and when. Cover every item — one short bullet '
        'each. Do not add anything that is not in the text, and do not write '
        'an introduction or a conclusion; this is one part of $of and will be '
        'combined with the others.',
      )
      // The budget is the feature's speed, not tidiness. Generation dominates
      // the cost of a batch, so an unbounded reply is an unbounded wait — and
      // it is what pushed the reduce past the context window.
      ..writeln(
        'Keep the entire reply under $maxCondensationChars characters.',
      )
      ..writeln();
    for (var i = 0; i < batch.length; i++) {
      buffer.writeln(batch[i].render(index * batchSize + i + 1, _charsPerItem));
    }
    return buffer.toString();
  }

  String _reducePrompt(ParsedQuery query, List<String> parts, int items) {
    final buffer = StringBuffer()
      ..writeln(
        'Below are ${parts.length} partial summaries covering $items results '
        'from a personal archive, matching: "${query.raw}".',
      )
      ..writeln()
      ..writeln(
        'Merge them into one summary. Group related points, keep names and '
        'dates, drop repetition, and do not introduce anything the partial '
        'summaries do not say.',
      );
    for (var i = 0; i < parts.length; i++) {
      buffer
        ..writeln()
        ..writeln('--- Part ${i + 1} of ${parts.length} ---')
        ..writeln(parts[i]);
    }
    return buffer.toString();
  }

  /// The default [ChatCompletion]: one non-streaming call to the local service.
  ///
  /// Deliberately the same endpoint the chat page and the image describer use,
  /// rather than a second inference path. It is not routed through
  /// `LocalLlmContentGenerator` because that adapts the endpoint to genui's
  /// streaming conversation surface, and a batch condensation is an
  /// intermediate artifact — putting one in the transcript per batch would
  /// show the user the working rather than the answer.
  static Future<String?> _aiServerCompletion(
    String prompt,
    void Function(SummarizeFailure) onFailure,
  ) async {
    final serviceUrl = MainApp.llmServiceUrl.valueOrNull;
    if (serviceUrl == null || serviceUrl.isEmpty) {
      onFailure(SummarizeFailure.serviceUnavailable);
      return null;
    }

    try {
      final response = await http
          .post(
            Uri.parse('$serviceUrl/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              ...aiServerAuthHeaders(MainApp.llmServiceToken.valueOrNull),
            },
            body: jsonEncode({
              'messages': [
                {'role': 'user', 'content': prompt},
              ],
              'stream': false,
            }),
          )
          .timeout(perCallTimeout);

      if (response.statusCode != 200) {
        _logger.e('Summarize: ${response.statusCode} ${response.body}');
        onFailure(SummarizeFailure.modelError);
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        onFailure(SummarizeFailure.modelError);
        return null;
      }
      final message = (choices.first as Map)['message'] as Map?;
      final content = message?['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        onFailure(SummarizeFailure.modelError);
      }
      return content;
    } on TimeoutException catch (e) {
      _logger.e('Summarize: $e');
      onFailure(SummarizeFailure.timedOut);
      return null;
    } catch (e) {
      _logger.e('Summarize: $e');
      onFailure(SummarizeFailure.serviceUnavailable);
      return null;
    }
  }
}

/// Writes a finished summary into `aichat` as a real conversation.
///
/// Seeded as two messages — the request, then the answer — rather than as text
/// dropped in the composer. Prefilling made it look as though the user had
/// typed a summary of their own archive, which leaves the model to guess what
/// to do with it; a user turn followed by an assistant turn is simply what a
/// finished exchange looks like, so the next thing typed is a follow-up.
///
/// Persisted rather than held in memory for the same reason the search page
/// does not keep results in a field: navigating away must not silently destroy
/// forty minutes of local inference. It also puts the summary in the
/// conversation list, where it can be found again.
class SummaryChatHandoff {
  const SummaryChatHandoff(this.repo);

  final AichatRepository repo;

  /// Supporting detail carried alongside the summary.
  ///
  /// Budgeted against the 32,768-token window (`model_manager.py`) — roughly
  /// 130k characters including the reply — with room left for the summary and
  /// several turns of conversation. Dropped entirely rather than truncated
  /// when it will not fit: half a batch summary is detail that reads as
  /// complete and is not.
  static const maxDetailChars = 60000;

  /// Body characters kept per result in the source material.
  ///
  /// Larger than the summarizer's own per-item budget, because these are read
  /// to answer specific questions rather than to be condensed — "what was the
  /// technical question, and what was the answer" needs the exchange, not the
  /// gist of it.
  static const sourceCharsPerItem = 3000;

  /// Creates the conversation and returns its id.
  Future<String> create(ParsedQuery query, ResultSetSummary summary) async {
    final title = query.raw.trim().isEmpty ? 'search results' : query.raw.trim();
    final conversation = await repo.createConversation(
      name: 'Summary: ${_clipName(title)}',
    );

    await repo.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: 'Summarize my archive matching "$title".',
    );
    // The coverage sentence travels inside the message, not beside it. Once
    // this is chat history it is the only thing left saying whether the
    // summary is of everything or of a slice, and that is exactly what the
    // next few turns will lean on.
    await repo.addMessage(
      conversationId: conversation.id,
      role: 'assistant',
      content: '${summary.coverageStatement}\n\n${summary.text}',
    );

    // Prefer the results themselves over the summary of them.
    //
    // Map-reduce exists because 412 messages do not fit a context window. 18
    // do — comfortably — and making the model answer follow-ups from a
    // compressed version of material that would have fit is a loss for no
    // reason. So: the sources when they fit, the batch summaries when they do
    // not, and nothing when neither does.
    final sources = summary.sources.join('\n\n');
    final parts = summary.parts.join('\n\n');
    final (label, detail) = switch ((
      sources.isNotEmpty && sources.length <= maxDetailChars,
      summary.parts.length > 1 && parts.length <= maxDetailChars,
    )) {
      (true, _) => ('the results themselves', sources),
      (false, true) => ('condensed notes, one per batch of results', parts),
      _ => ('', ''),
    };

    if (detail.isNotEmpty) {
      // Role `system`, so it reaches the model without appearing in the
      // transcript as something the user or the assistant said. It is context,
      // not a turn — see the render filter in `aichat_page.dart`.
      await repo.addMessage(
        conversationId: conversation.id,
        role: 'system',
        content:
            'Source material for the summary above — $label. Answer questions '
            'about these results using this material, and say so plainly when '
            'the answer is not in it.\n\n$detail',
      );
    }

    return conversation.id;
  }

  static String _clipName(String name) =>
      name.length <= 60 ? name : '${name.substring(0, 60)}…';
}

/// One result reduced to the text a summary can be built from.
class _SummaryItem {
  const _SummaryItem({
    required this.title,
    required this.subtitle,
    required this.date,
    required this.body,
  });

  final String title;
  final String? subtitle;
  final DateTime? date;
  final String body;

  String render(int number, int bodyLimit) {
    final when = date?.toIso8601String().split('T').first ?? 'undated';
    final who = subtitle == null || subtitle!.isEmpty ? '' : ' — $subtitle';
    final text =
        body.length <= bodyLimit ? body : '${body.substring(0, bodyLimit)}…';
    return '[$number] $when$who — "$title"\n$text\n';
  }
}
