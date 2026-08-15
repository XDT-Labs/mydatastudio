import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion_service.dart';

/// A provider over a fixed list, counting how often it reloaded.
class _FakeProvider extends CachedFieldSuggestionProvider {
  _FakeProvider(this._entries);

  final List<FieldSuggestion> _entries;
  int loads = 0;

  @override
  Set<FilterField> get fields => const {FilterField.from};

  @override
  Future<List<FieldSuggestion>> load() async {
    loads++;
    return _entries;
  }
}

const _mike = FieldSuggestion(
  value: 'mike@xdtlabs.com',
  label: 'Mike Nimer',
  detail: 'mike@xdtlabs.com',
  count: 412,
);
const _adminMike = FieldSuggestion(
  value: 'adminmike@example.com',
  label: 'adminmike@example.com',
  count: 900,
);
const _milly = FieldSuggestion(
  value: 'milly@example.com',
  label: 'Milly Barnes',
  count: 2,
);

void main() {
  group('rankSuggestions — ordering', () {
    test('a prefix match outranks a busier substring match', () {
      // The rule that makes short prefixes usable. Ordering by volume alone
      // would put `adminmike` (900) above `Mike Nimer` (412) for the query
      // "mi", which is never what someone typing two characters means.
      final ranked = rankSuggestions([_adminMike, _mike, _milly], 'mi');
      expect(ranked.first.value, 'mike@xdtlabs.com');
      expect(ranked.last.value, 'adminmike@example.com');
    });

    test('within a tier, correspondence volume decides', () {
      // Both prefix-match "mi"; 412 messages beats 2. Alphabetical order would
      // invert this and bury the person the user actually writes to.
      final ranked = rankSuggestions([_milly, _mike], 'mi');
      expect(ranked.map((s) => s.value), [
        'mike@xdtlabs.com',
        'milly@example.com',
      ]);
    });

    test('matching is case-insensitive in both directions', () {
      expect(rankSuggestions([_mike], 'MIKE'), isNotEmpty);
      expect(rankSuggestions([_mike], 'nimer'), isNotEmpty);
    });

    test('a contact is findable by address as well as by name', () {
      // The user has no way to know which of the two is stored, so both have
      // to match — "xdtlabs" appears only in the address.
      expect(rankSuggestions([_mike], 'xdtlabs'), isNotEmpty);
    });

    test('an empty query returns the head of the list by volume', () {
      // `from:` with nothing typed is a real state, and showing top
      // correspondents there is the point — not an empty dropdown.
      final ranked = rankSuggestions([_milly, _mike, _adminMike], '');
      expect(ranked.first.value, 'adminmike@example.com');
      expect(ranked, hasLength(3));
    });

    test('no match returns empty rather than everything', () {
      expect(rankSuggestions([_mike, _milly], 'zzzz'), isEmpty);
    });

    test('ties order identically every time', () {
      // Suggestions rebuild on each keystroke; rows that reshuffle under the
      // cursor make the list impossible to click.
      const a = FieldSuggestion(value: 'a@x.com', label: 'a@x.com', count: 5);
      const b = FieldSuggestion(value: 'b@x.com', label: 'b@x.com', count: 5);
      expect(rankSuggestions([a, b], '').map((s) => s.value),
          rankSuggestions([b, a], '').map((s) => s.value));
    });

    test('the limit caps the list', () {
      final ranked = rankSuggestions([_mike, _milly, _adminMike], '', limit: 2);
      expect(ranked, hasLength(2));
    });
  });

  group('CachedFieldSuggestionProvider — the DB is not in the keystroke path', () {
    test('typing repeatedly loads the source exactly once', () async {
      // §13e: the whole suggestion corpus is under 100 KB, so it is held in
      // memory and filtered in Dart. A reload per keystroke is the cost this
      // cache exists to remove.
      final provider = _FakeProvider([_mike, _milly]);
      await provider.suggest(FilterField.from, 'm');
      await provider.suggest(FilterField.from, 'mi');
      await provider.suggest(FilterField.from, 'mik');
      expect(provider.loads, 1);
    });

    test('concurrent first keystrokes share one load', () async {
      final provider = _FakeProvider([_mike]);
      await Future.wait([
        provider.suggest(FilterField.from, 'm'),
        provider.suggest(FilterField.from, 'mi'),
      ]);
      expect(provider.loads, 1);
    });

    test('invalidate reloads, so a completed sync shows up', () async {
      final provider = _FakeProvider([_mike]);
      await provider.suggest(FilterField.from, 'm');
      provider.invalidate();
      await provider.suggest(FilterField.from, 'm');
      expect(provider.loads, 2);
    });
  });

  group('FieldSuggestionService — dispatch', () {
    test('a field with no provider yields nothing instead of throwing', () async {
      // The caret sits in `subject:` and `after:` constantly. A search box has
      // no business failing because it has nothing to suggest.
      final service = FieldSuggestionService([_FakeProvider(const [])]);
      expect(await service.suggest(FilterField.subject, 'x'), isEmpty);
      expect(service.supports(FilterField.subject), isFalse);
    });

    test('static fields serve their own vocabulary, not each other\'s', () async {
      // One provider, three fields, three disjoint vocabularies — the case
      // that made the field a parameter rather than a per-provider constant.
      const service = StaticSuggestionProvider();
      expect(
        (await service.suggest(FilterField.is_, '')).map((s) => s.value),
        containsAll(['read', 'unread']),
      );
      expect(
        (await service.suggest(FilterField.type, '')).map((s) => s.value),
        isNot(contains('unread')),
      );
    });

    test('every provider field is reachable through the service', () async {
      final service = FieldSuggestionService([
        _FakeProvider([_mike]),
        const StaticSuggestionProvider(),
      ]);
      expect(service.supports(FilterField.from), isTrue);
      expect(service.supports(FilterField.type), isTrue);
      expect(await service.suggest(FilterField.from, 'mi'), isNotEmpty);
    });
  });

  group('suggestions never gate what can be searched', () {
    test('an address absent from the index is still a valid filter', () {
      // §13d: the dropdown suggests, it does not constrain. Mail may have been
      // deleted, or not yet synced — free text must keep working, or search
      // becomes unable to look for anything the index has not already seen.
      final parsed = QueryParser.parse('from:stranger@nowhere.com');
      expect(parsed.filters.single.field, FilterField.from);
      expect(parsed.filters.single.value, 'stranger@nowhere.com');
    });
  });
}
