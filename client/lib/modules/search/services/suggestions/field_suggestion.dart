import '../../models/search_query.dart';

/// One offered value for a `field:` in the search box.
///
/// [value] is what gets inserted into the query and must be something the
/// filter can match exactly — an address, a tag, a collection name. Everything
/// else on this class exists only to help the user choose between two rows that
/// would otherwise look the same.
class FieldSuggestion {
  /// The canonical value inserted into the query when this is accepted.
  final String value;

  /// Primary line: the human-readable name where one exists, else [value].
  final String label;

  /// Secondary line, shown beside [label]. Null when it would just repeat it.
  final String? detail;

  /// How many records carry this value. Zero for fields with a fixed
  /// vocabulary, where counting would mean nothing.
  final int count;

  const FieldSuggestion({
    required this.value,
    required this.label,
    this.detail,
    this.count = 0,
  });

  @override
  String toString() => 'FieldSuggestion($value, $label, n=$count)';
}

/// Filters and orders [all] against what the user has typed.
///
/// Ranking rules, in order, and each is load-bearing:
///
/// - **Prefix before substring.** Typing `mi` must put `Mike Nimer` above
///   `adminmike@x.com`. Ordering purely by volume would let a high-traffic
///   substring match displace the obvious answer.
/// - **Then by [FieldSuggestion.count], descending.** Someone with 400 messages
///   outranks someone with 2. Alphabetical order would be an accident of
///   spelling, and for `tag:` — a vocabulary of a thousand machine-generated
///   words — it would be useless.
/// - **Then by value**, so equal candidates never reorder between rebuilds.
///
/// Matching is case-insensitive and tries both [FieldSuggestion.label] and
/// [FieldSuggestion.value], because a contact is findable by either their name
/// or their address and the user has no reason to know which one is stored.
List<FieldSuggestion> rankSuggestions(
  Iterable<FieldSuggestion> all,
  String typed, {
  int limit = 8,
}) {
  final needle = typed.trim().toLowerCase();

  final scored = <(int, FieldSuggestion)>[];
  for (final suggestion in all) {
    final tier = needle.isEmpty ? 0 : _matchTier(suggestion, needle);
    if (tier == null) continue;
    scored.add((tier, suggestion));
  }

  scored.sort((a, b) {
    final byTier = a.$1.compareTo(b.$1);
    if (byTier != 0) return byTier;
    final byCount = b.$2.count.compareTo(a.$2.count);
    if (byCount != 0) return byCount;
    return a.$2.value.compareTo(b.$2.value);
  });

  return [for (final entry in scored.take(limit)) entry.$2];
}

/// 0 for a prefix match, 1 for a substring match, null for no match.
int? _matchTier(FieldSuggestion suggestion, String needle) {
  final label = suggestion.label.toLowerCase();
  final value = suggestion.value.toLowerCase();

  if (label.startsWith(needle) || value.startsWith(needle)) return 0;
  if (label.contains(needle) || value.contains(needle)) return 1;
  return null;
}

/// Supplies the values offered for one or more `field:` names.
///
/// One implementation per source, dispatched on the field the caret sits in, so
/// a new completable field is a new provider rather than new UI. Providers hold
/// their whole value list in memory and filter in Dart — see §13e of the search
/// plan: the entire suggestion corpus across every field measures under 100 KB,
/// so putting SQLite in the keystroke path buys nothing and costs the useful
/// one- and two-character cases that a minimum-length gate would block.
abstract class FieldSuggestionProvider {
  /// The fields this provider answers for.
  Set<FilterField> get fields;

  /// Values for [field] matching [typed], best first. An empty [typed] returns
  /// the head of the list, which is what makes `tag:` discoverable at all.
  ///
  /// [field] is passed even though most providers serve a single field: the
  /// ones that serve several are split between those where the vocabulary is
  /// shared (one address list across `from:`/`to:`/`cc:`) and those where it
  /// differs per field (`type:` and `is:` have nothing in common). Without it
  /// the second kind cannot be written against this interface at all.
  Future<List<FieldSuggestion>> suggest(
    FilterField field,
    String typed, {
    int limit,
  });

  /// Drops the cached list so the next call reloads it.
  void invalidate();
}

/// A provider that loads its values once and filters them in memory.
abstract class CachedFieldSuggestionProvider implements FieldSuggestionProvider {
  List<FieldSuggestion>? _cache;
  Future<List<FieldSuggestion>>? _loading;

  /// Reads the full value list from its source. Called once per cache cycle.
  Future<List<FieldSuggestion>> load();

  @override
  Future<List<FieldSuggestion>> suggest(
    FilterField field,
    String typed, {
    int limit = 8,
  }) async {
    final entries = await _entries();
    return rankSuggestions(entries, typed, limit: limit);
  }

  Future<List<FieldSuggestion>> _entries() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);

    // Share one load between concurrent callers — keystrokes arrive faster
    // than a cold query returns, and a load per keystroke is the cost this
    // cache exists to avoid. Cleared on completion either way, so a failed
    // load retries on the next keystroke instead of caching the failure.
    return _loading ??= load()
        .then((rows) {
          _cache = rows;
          return rows;
        })
        .whenComplete(() => _loading = null);
  }

  @override
  void invalidate() {
    _cache = null;
  }
}
