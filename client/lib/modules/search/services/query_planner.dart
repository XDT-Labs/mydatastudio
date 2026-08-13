import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';

/// Asks the local model one question: which kind of thing is this search for?
///
/// This is the whole of the model's job in search (§2c). It cannot emit a
/// filter — no `from:`, no date range, nothing that decides *membership* — so
/// the worst a wrong answer can do is order the results badly. Everything that
/// has to be right stays in the parser and the retrievers.
///
/// It answers a question the deterministic parser genuinely cannot. `family
/// photos` names its modality and [QueryParser] strips it into
/// `preferredTypes`; `graduation speech` names nothing, and the archive holds
/// it as a video, a document, an attachment on mail, or all three. The parser
/// has no word to key on and correctly says nothing.
class QueryPlanner {
  QueryPlanner({PlannerTransport? transport})
    : transport = transport ?? _aiServerCompletion;

  static final AppLogger _logger = AppLogger(null);

  final PlannerTransport transport;

  /// The words the model is allowed to answer with.
  ///
  /// **`photo`, not `image` — and that is not cosmetic.** Measured against
  /// gemma4:12b on this archive: with `image` in the enum, every one of five
  /// photo queries (`white dog`, `snow mountains`, `wedding`, `kids soccer
  /// game`, `sunset over the lake`) answered `["video","video"]` and not one
  /// said `image`. Changing the single word to `photo` took the same twelve
  /// queries from 5 misses to 0. The enum is part of the prompt: the model was
  /// not confused about the query, it was answering in the only vocabulary it
  /// was offered, and `video` was the nearest word it had to the one it wanted.
  ///
  /// Translated to the app's own modality names by [_appTypes], because
  /// [SearchResult.modality] speaks `image`/`pdf`/`file` and a preference the
  /// results cannot be compared against is silently no preference at all.
  static const vocabulary = ['photo', 'video', 'email', 'document'];

  /// Bounded, and the bound is load-bearing rather than defensive.
  ///
  /// An unbounded `array` compiles to a GBNF rule that permits infinite
  /// repetition, and when the model's distribution over the enum is flat it
  /// never chooses the closing bracket. Measured: every photo query ran to the
  /// 64-token cap emitting `"video","video","video",…` — 3.5s and unparseable,
  /// where the bounded schema answers the same query in 1.1s. `maxItems` also
  /// says in the grammar what the prompt says in words.
  static const _schema = {
    'type': 'object',
    'properties': {
      'modalities': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 2,
        'items': {'type': 'string', 'enum': vocabulary},
      },
    },
    'required': ['modalities'],
  };

  /// §2c budgets this at ~800ms. Measured on this machine the call takes a
  /// median of **1.08s** (n=12, 1.01–1.15s) against a warm gemma4:12b, so an
  /// 800ms bound would discard nearly every answer it paid for.
  ///
  /// Three seconds is that median plus room for the one thing that genuinely
  /// makes it slower: `state.generation_lock` serializes generations, so a
  /// planner call fired while a summarize is running waits for it. Waiting
  /// longer would not help — by then the user has read the results.
  static const timeout = Duration(seconds: 3);

  /// Whether this query is one the model has anything to add to.
  ///
  /// Not "always ask" — an inferred preference that contradicts a stated one is
  /// strictly worse than no inference. A query that named a kind already has
  /// its answer, an explicit `type:` is the user being specific, and a pure
  /// filter query (`from:mike after:2026`) is a browse with nothing to reorder.
  static bool isAmbiguous(ParsedQuery query) {
    if (!query.hasFreeText) return false;
    if (query.preferredTypes.isNotEmpty) return false;
    return !query.filters.any((f) => f.field == FilterField.type);
  }

  /// The modalities to prefer, or null for "no opinion".
  ///
  /// Null on every failure — no service, no model, timeout, HTTP error,
  /// malformed JSON, a word outside [vocabulary], an answer naming everything.
  /// Search must never be worse for having asked, so there is no error path
  /// out of here, only silence.
  Future<Set<String>?> plan(ParsedQuery query) async {
    if (!isAmbiguous(query)) return null;

    final reply = await transport(_promptFor(query));
    if (reply == null) return null;

    final words = _modalitiesFrom(reply);
    if (words == null || words.isEmpty) return null;

    // Naming every kind is the same statement as naming none, and it costs a
    // page reorder to say it. Drop it here rather than boosting everything by
    // an equal multiplier and calling the unchanged order a refinement.
    if (words.length >= vocabulary.length) return null;

    final types = _appTypes(words);
    return types.isEmpty ? null : types;
  }

  /// The query as the model sees it.
  ///
  /// Asks where the answer *most likely* lives, not where it could. An earlier
  /// prompt carried the fail-open rule in words — "choose all four if unsure" —
  /// and the model took it as a licence: 5 of 10 queries came back naming all
  /// four kinds, including `white dog` and `snow mountains`. Failing open is
  /// the caller's job, and [plan] does it in code where a model cannot talk
  /// itself out of an opinion.
  ///
  /// Only [ParsedQuery.freeText] is sent. The filters are already resolved and
  /// none of the model's business, and the raw string can carry an address the
  /// user did not choose to hand an inference engine.
  static String _promptFor(ParsedQuery query) {
    return 'A personal archive holds photos, videos, email and documents.\n'
        'Someone searched it for: "${query.freeText}"\n'
        'Which one or two kinds is the thing they are looking for most likely '
        'to be? Answer with JSON only, most likely first.';
  }

  /// The `modalities` array from a reply, or null if it is not one.
  static List<String>? _modalitiesFrom(String reply) {
    try {
      final decoded = jsonDecode(_stripJsonFence(reply));
      if (decoded is! Map) return null;
      final raw = decoded['modalities'];
      if (raw is! List) return null;
      final words = <String>{};
      for (final entry in raw) {
        final word = entry.toString().toLowerCase().trim();
        // A word outside the enum means the grammar was not applied, and an
        // answer from an unconstrained model is not one this can act on.
        if (!vocabulary.contains(word)) return null;
        words.add(word);
      }
      return words.toList();
    } catch (e) {
      _logger.d('QueryPlanner: unparseable plan, no preference: $e');
      return null;
    }
  }

  /// The model's words as [SearchResult.modality] values.
  ///
  /// `document` maps to both `pdf` and `file` because `modality` collapses
  /// every non-image, non-video, non-PDF file — Word, text, everything — into
  /// `file`. Over-broad on purpose: the alternative is a stated preference for
  /// documents that lifts PDFs and leaves .docx behind. It only ever reorders
  /// results the query already retrieved, so a binary nobody searched for is
  /// not in the list to be lifted.
  static Set<String> _appTypes(List<String> words) {
    return {
      for (final word in words)
        ...switch (word) {
          'photo' => const ['image'],
          'video' => const ['video'],
          'email' => const ['email'],
          'document' => const ['pdf', 'file'],
          _ => const <String>[],
        },
    };
  }

  /// Grammar-constrained decoding is supposed to make this unnecessary, but
  /// llama.cpp does not reliably apply it across handlers — the same insurance
  /// `FileDescriptionIsolate.stripJsonFence` carries, for the same reason.
  static String _stripJsonFence(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final withoutOpen = trimmed.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*\n?'), '');
    final close = withoutOpen.lastIndexOf('```');
    return close == -1
        ? withoutOpen.trim()
        : withoutOpen.substring(0, close).trim();
  }

  static Future<String?> _aiServerCompletion(String prompt) async {
    final serviceUrl = MainApp.llmServiceUrl.valueOrNull;
    if (serviceUrl == null || serviceUrl.isEmpty) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$serviceUrl/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              ...aiServerAuthHeaders(MainApp.llmServiceToken.valueOrNull),
            },
            body: jsonEncode({
              // No 'model': the default chat alias, the same one the rest of
              // the app talks to, so this never causes a second model load.
              'messages': [
                {'role': 'user', 'content': prompt},
              ],
              'stream': false,
              'temperature': 0,
              // The bounded answer is 17 tokens. The cap is what stops a
              // degenerate grammar loop from costing seconds.
              'max_tokens': 64,
              'response_format': {'type': 'json_object', 'schema': _schema},
            }),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        _logger.d('QueryPlanner: ${response.statusCode}, no preference');
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final message = (choices.first as Map<String, dynamic>)['message'];
      return message is Map ? message['content'] as String? : null;
    } catch (e) {
      _logger.d('QueryPlanner: $e, no preference');
      return null;
    }
  }
}

/// The one seam: a prompt in, the model's raw reply out, null for any failure.
typedef PlannerTransport = Future<String?> Function(String prompt);
