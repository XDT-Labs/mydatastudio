import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/email_contact_repository.dart';

/// Turns `emails from mike nimer` into the same plan as `from:mnimer@x.com`.
///
/// §2b of the search plan: the colon syntax is a shortcut, not the destination.
/// Both forms state a constraint on the sender and both must produce a hard
/// filter, because the obvious alternative — letting the prose fall through to
/// vector search — is wrong on the merits. Embeddings encode meaning, not
/// identity. Embedding "from mike nimer" retrieves messages *about* Mike, or
/// that mention his name, while systematically missing messages *from* Mike on
/// unrelated topics, and that missed set is exactly what was asked for. Proper
/// nouns are the weakest thing a semantic vector carries.
///
/// This runs as a pass over an already-parsed query rather than inside
/// [QueryParser], which is a pure synchronous function on purpose — resolution
/// is a database lookup, and putting one on the keystroke path would make every
/// character typed a race. Same shape as `NearResolver`, for the same reason.
///
/// The lookup is a database question, not a model one: the archive knows which
/// addresses a name corresponds to and a language model does not.
class PersonResolver {
  final EmailContactRepository contacts;

  PersonResolver(AppDatabase db) : contacts = EmailContactRepository(db);

  PersonResolver.withRepository(this.contacts);

  /// Prepositions that make the following words a person rather than a topic,
  /// and the field each constrains.
  ///
  /// `with` and `between` map to [FilterField.participant] rather than to
  /// `from:`, because they do not name a direction. "My emails with Sarah" is
  /// the whole correspondence, and a thread alternates direction with every
  /// reply — resolved to `from:` it would return half of it.
  static const _triggers = <String, FilterField>{
    'from': FilterField.from,
    'to': FilterField.to,
    'with': FilterField.participant,
    'between': FilterField.participant,
  };

  /// Joins a second person onto a participant constraint: "between mike **and**
  /// sarah".
  ///
  /// Only for [FilterField.participant]. "from mike and sarah" means either —
  /// a message has one sender — while "between mike and sarah" means both, and
  /// those are opposite combinators. Consuming `and` for the directional fields
  /// would silently turn one into the other.
  static const _conjunction = 'and';

  /// Longest name to try. Four covers "mike nimer", "jean claude van damme",
  /// and stops the scan running away into the rest of the sentence.
  static const _maxNameWords = 4;

  /// Words that follow a trigger but never name a person.
  ///
  /// "from me" and "from work" would otherwise resolve — `resolveName` matches
  /// substrings, so "work" finds "Network Solutions" — and a hard filter built
  /// on that returns the wrong mail with no sign anything went wrong.
  static const _notNames = {
    'me',
    'my',
    'mine',
    'us',
    'we',
    'them',
    'him',
    'her',
    'anyone',
    'everyone',
    'someone',
    'work',
    'home',
    'today',
    'yesterday',
    'last',
    'this',
  };

  Future<ParsedQuery> resolve(ParsedQuery query) async {
    if (!query.hasFreeText) return query;

    final words = query.freeText.split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.length < 2) return query;

    final added = <QueryFilter>[];
    final kept = <String>[];

    var i = 0;
    while (i < words.length) {
      final field = _triggers[words[i].toLowerCase()];
      if (field == null) {
        kept.add(words[i]);
        i++;
        continue;
      }

      // The user typing `from:` themselves outranks anything inferred from
      // prose — they already supplied the address, and a second constraint on
      // the same field would narrow it to nothing.
      if (query.filtersFor(field).any((f) => !f.negated)) {
        kept.add(words[i]);
        i++;
        continue;
      }

      final match = await _longestNameAfter(words, i, field);
      if (match == null) {
        kept.add(words[i]);
        i++;
        continue;
      }

      added.addAll(match.filters);
      // The trigger goes with the name. Leaving "from" behind would make FTS5
      // demand the word "from" of every row — it joins terms with an implicit
      // AND — and mail whose body never says "from" would drop out.
      i += match.wordCount + 1;

      // "between mike and sarah" — each further person is its own constraint,
      // AND'd by SearchFilters because they arrive under different source text.
      while (field == FilterField.participant &&
          i < words.length &&
          words[i].toLowerCase() == _conjunction) {
        final next = await _longestNameAfter(words, i, field);
        if (next == null) break;
        added.addAll(next.filters);
        i += next.wordCount + 1;
      }
    }

    if (added.isEmpty) return query;

    return query.copyWith(
      filters: [...query.filters, ...added],
      freeText: kept.join(' '),
    );
  }

  /// The longest run of words after [triggerIndex] that names someone in the
  /// archive, as filters.
  ///
  /// Longest-first so "from mike nimer" prefers the person over the several
  /// different Mikes that "mike" alone would match. A run stops at the next
  /// trigger word, so "from mike to sarah" cannot swallow "to sarah" into the
  /// sender's name.
  Future<_NameMatch?> _longestNameAfter(
    List<String> words,
    int triggerIndex,
    FilterField field,
  ) async {
    final maxLength = _runLengthAfter(words, triggerIndex);
    for (var n = maxLength; n >= 1; n--) {
      final phrase = words.sublist(triggerIndex + 1, triggerIndex + 1 + n);
      if (_notNames.contains(phrase.first.toLowerCase())) continue;

      final name = phrase.join(' ');
      final matches = await contacts.resolveName(name);
      final accepted = matches.where((c) => _isRealMatch(name, c)).toList();
      if (accepted.isEmpty) continue;

      // Every address the person uses, OR'd — SearchFilters ORs repeats of one
      // field. Returning them all rather than picking is the point: this
      // archive has `mnimer@allaire.com` and `mike@digitalchef.com` under one
      // display name, and choosing between them would drop half the answer.
      // When they are genuinely different people, the filters are visible as
      // chips and individually removable, which is the correction path.
      return _NameMatch(
        wordCount: n,
        filters: [
          for (final contact in accepted)
            QueryFilter(
              field: field,
              value: contact.address,
              sourceText: '${words[triggerIndex]} $name',
            ),
        ],
      );
    }
    return null;
  }

  /// How many words after [triggerIndex] are available to a name, stopping
  /// before the next trigger word or conjunction.
  ///
  /// Stopping at `and` matters for both readings. For a participant query it is
  /// the boundary between two people. For a directional one — "from mike and
  /// sarah" — it keeps "mike and sarah" from being offered to the index as a
  /// single name, which a display name containing either word could match by
  /// accident.
  static int _runLengthAfter(List<String> words, int triggerIndex) {
    var length = 0;
    for (var j = triggerIndex + 1; j < words.length; j++) {
      final word = words[j].toLowerCase();
      if (_triggers.containsKey(word) || word == _conjunction) break;
      length++;
      if (length == _maxNameWords) break;
    }
    return length;
  }

  /// Whether [name] really names [contact], as opposed to merely appearing
  /// inside its text.
  ///
  /// [EmailContactRepository.resolveName] matches substrings, which is right
  /// for autocomplete — typing "mik" should offer Mike — but wrong here,
  /// because this builds a filter that *removes* results. A single word has to
  /// match a whole word of the display name or the whole local part, so "from
  /// ann" does not resolve to "Joanne" and quietly hide everything else.
  ///
  /// A multi-word phrase is left to the repository's ordered match: two words
  /// in sequence are specific enough that a substring hit is almost certainly
  /// the person, and requiring whole words there would lose "mike n" and
  /// hyphenated or middle-name variants.
  static bool _isRealMatch(String name, EmailContact contact) {
    if (name.contains(' ')) return true;

    final needle = name.toLowerCase();
    if (contact.localPart.toLowerCase() == needle) return true;

    final displayName = contact.displayName;
    if (displayName == null) return false;
    return displayName
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .any((word) => word == needle);
  }
}

class _NameMatch {
  const _NameMatch({required this.wordCount, required this.filters});

  /// Words of the name itself, not counting the trigger.
  final int wordCount;
  final List<QueryFilter> filters;
}
