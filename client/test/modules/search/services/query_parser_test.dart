import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';

void main() {
  group('QueryParser.parse - filter/free-text split', () {
    test('splits a leading filter from trailing free text', () {
      // The whole point of the parser: filters constrain, free text ranks.
      // If this split is wrong every downstream query is wrong.
      final result = QueryParser.parse('from:bob@x.com landscape photos');
      expect(result.filters, [
        const QueryFilter(field: FilterField.from, value: 'bob@x.com'),
      ]);
      // "photos" is lifted out as a modality preference — see that group
      // below — leaving the words that actually describe what is wanted.
      expect(result.freeText, 'landscape');
    });

    test('collects filters interleaved with free text in original order', () {
      final result = QueryParser.parse('sunset type:image over the lake');
      expect(result.filtersFor(FilterField.type), [
        const QueryFilter(field: FilterField.type, value: 'image'),
      ]);
      expect(result.freeText, 'sunset over the lake');
    });
  });

  group('QueryParser.parse - quoted values', () {
    test('quoted multi-word value stays intact as one filter value', () {
      final result = QueryParser.parse('in:"Work Gmail" invoices');
      expect(result.filtersFor(FilterField.in_), [
        const QueryFilter(field: FilterField.in_, value: 'Work Gmail'),
      ]);
      expect(result.freeText, 'invoices');
    });

    test('quoted value containing a colon is not mistaken for a new field', () {
      // subject:"re: hello" must not parse as field "subject" value "re"
      // followed by a stray ": hello" token.
      final result = QueryParser.parse('subject:"re: hello"');
      expect(result.filters, [
        const QueryFilter(field: FilterField.subject, value: 're: hello'),
      ]);
      expect(result.freeText, '');
    });

    test(
      'unterminated quote consumes to end of string instead of throwing',
      () {
        final result = QueryParser.parse('subject:"foo');
        expect(result.filters, [
          const QueryFilter(field: FilterField.subject, value: 'foo'),
        ]);
      },
    );
  });

  group('QueryParser.parse - negation', () {
    test(
      'leading dash marks the filter negated without altering the value',
      () {
        final result = QueryParser.parse('-from:spam@x.com inbox');
        expect(result.filters, [
          const QueryFilter(
            field: FilterField.from,
            value: 'spam@x.com',
            negated: true,
          ),
        ]);
        expect(result.freeText, 'inbox');
      },
    );
  });

  group('QueryParser.parse - repeated fields', () {
    test('same field repeated keeps both filters for the caller to OR', () {
      final result = QueryParser.parse('from:a@x.com from:b@x.com');
      expect(result.filtersFor(FilterField.from), [
        const QueryFilter(field: FilterField.from, value: 'a@x.com'),
        const QueryFilter(field: FilterField.from, value: 'b@x.com'),
      ]);
    });
  });

  group('QueryParser.parse - date filters', () {
    test('full yyyy-MM-dd date parses to that exact day', () {
      final result = QueryParser.parse('after:2026-01-15');
      final filter = result.filters.single;
      expect(filter.field, FilterField.after);
      expect(filter.value, '2026-01-15');
      expect(filter.dateValue, DateTime(2026, 1, 15));
    });

    test('yyyy-MM date defaults to the first of the month', () {
      final result = QueryParser.parse('before:2026-01');
      final filter = result.filters.single;
      expect(filter.field, FilterField.before);
      expect(filter.dateValue, DateTime(2026, 1, 1));
    });

    test('yyyy-only date defaults to January 1st', () {
      final result = QueryParser.parse('after:2026');
      final filter = result.filters.single;
      expect(filter.dateValue, DateTime(2026, 1, 1));
    });

    test('invalid calendar date falls through to free text, not a filter', () {
      // A day that doesn't exist (Feb 30) must degrade gracefully rather
      // than silently producing a wrong DateTime.
      final result = QueryParser.parse('after:2026-02-30 party');
      expect(result.filtersFor(FilterField.after), isEmpty);
      expect(result.freeText, 'after:2026-02-30 party');
    });

    test('non-date value falls through to free text', () {
      final result = QueryParser.parse('after:notadate');
      expect(result.hasFilters, isFalse);
      expect(result.freeText, 'after:notadate');
    });
  });

  group('QueryParser.parse - bare year in free text', () {
    test('standalone 4-digit year becomes an implicit after/before range', () {
      final result = QueryParser.parse('party pictures from 2026');
      expect(
        result.filtersFor(FilterField.after).single.dateValue,
        DateTime(2026, 1, 1),
      );
      expect(
        result.filtersFor(FilterField.before).single.dateValue,
        DateTime(2027, 1, 1),
      );
      // Only the year token is removed - "from" is an English word here,
      // not a field name, and must stay in the free text.
      expect(result.freeText, 'party from');
    });

    test(
      'bare year is left alone when an explicit after/before already won',
      () {
        // Explicit filters are the user being precise; an implicit guess must
        // never override or duplicate that intent.
        final result = QueryParser.parse('after:2020 pictures 2026');
        expect(result.filtersFor(FilterField.after), [
          QueryFilter(
            field: FilterField.after,
            value: '2020',
            dateValue: DateTime(2020, 1, 1),
          ),
        ]);
        expect(result.filtersFor(FilterField.before), isEmpty);
        expect(result.freeText, '2026');
      },
    );

    test('only the first of multiple bare years is consumed', () {
      final result = QueryParser.parse('2026 vs 2027 comparison');
      expect(
        result.filtersFor(FilterField.after).single.dateValue,
        DateTime(2026, 1, 1),
      );
      expect(result.freeText, 'vs 2027 comparison');
    });

    test('year outside 1900-2100 is left as plain free text', () {
      final result = QueryParser.parse('model 3050');
      expect(result.hasFilters, isFalse);
      expect(result.freeText, 'model 3050');
    });
  });

  group('QueryParser.parse - modality words in free text', () {
    test('naming a kind is a preference, never a filter', () {
      // Deliberately not a filter. "family photos" should lead with
      // photographs, but the thread those photos were sent in belongs in the
      // results too — and a type: filter would zero the Emails facet, turning
      // the control the user needs into a dead end.
      final result = QueryParser.parse('family photos');

      expect(result.preferredTypes, {'image'});
      expect(result.filtersFor(FilterField.type), isEmpty);
      // The word is removed, and that is load-bearing rather than tidiness:
      // FTS5 ANDs its terms, and an AI image description says "a family
      // standing together outdoors", never "photos" — so keeping it would
      // exclude from the lexical pass exactly the photographs being asked
      // for. The mail still matches on "family".
      expect(result.freeText, 'family');
      expect(result.prefers('image'), isTrue);
      expect(result.prefers('email'), isFalse);
    });

    test('every spelling of the same modality resolves alike', () {
      for (final word in ['photo', 'pictures', 'pics', 'images']) {
        final result = QueryParser.parse('beach $word');
        expect(result.preferredTypes, {
          'image',
        }, reason: '"$word" should name the image modality');
      }
    });

    test('naming two kinds prefers both rather than picking one', () {
      final result = QueryParser.parse('vacation photos videos');
      expect(result.preferredTypes, {'image', 'video'});
      expect(result.freeText, 'vacation');
    });

    test('a query that is only a modality word browses that kind', () {
      // The one case where constraining is right. Strip the word and nothing
      // is left to search for, and "photos" alone is not a ranking hint — it
      // is a request to see every photo.
      final result = QueryParser.parse('photos');
      expect(result.filtersFor(FilterField.type), [
        const QueryFilter(field: FilterField.type, value: 'image'),
      ]);
      expect(result.preferredTypes, isEmpty);
      expect(result.hasFilters, isTrue);
    });

    test('an explicit type: is never second-guessed', () {
      // The user being specific outranks anything inferred from prose, and an
      // explicit type: stays a real filter rather than a preference.
      final result = QueryParser.parse('type:pdf photos');
      expect(result.preferredTypes, isEmpty);
      expect(result.filtersFor(FilterField.type), [
        const QueryFilter(field: FilterField.type, value: 'pdf'),
      ]);
    });

    test('a query naming no kind states no preference', () {
      // Distinct from naming a kind and missing it: with nothing stated,
      // nothing should be lifted or held back.
      final result = QueryParser.parse('white dog');
      expect(result.preferredTypes, isEmpty);
      expect(result.prefers('image'), isNull);
    });

    test('ordinary content words state no preference', () {
      // "document" reads as content at least as often as intent — "the
      // document you sent" describes an email — so even a mild boost would
      // reorder results for a phrase never meant as a hint.
      final result = QueryParser.parse('the document you sent');
      expect(result.preferredTypes, isEmpty);
    });

    test('matching is case-insensitive', () {
      expect(QueryParser.parse('Family Pictures').preferredTypes, {'image'});
    });
  });

  group('QueryParser.parse - near field', () {
    test('bare place name defaults to a 25km radius', () {
      final result = QueryParser.parse('near:banff');
      final filter = result.filters.single;
      expect(filter.field, FilterField.near);
      expect(filter.value, 'banff');
      expect(filter.radiusKm, 25);
    });

    test('explicit radius suffix overrides the default', () {
      final result = QueryParser.parse('near:banff:50');
      final filter = result.filters.single;
      expect(filter.value, 'banff');
      expect(filter.radiusKm, 50);
    });

    test('non-numeric suffix is folded back into the place name', () {
      final result = QueryParser.parse('near:banff:abc');
      final filter = result.filters.single;
      expect(filter.value, 'banff:abc');
      expect(filter.radiusKm, 25);
    });
  });

  group('QueryParser.parse - unknown fields', () {
    test('unrecognized field name is not treated as a filter', () {
      final result = QueryParser.parse('foo:bar landscape');
      expect(result.hasFilters, isFalse);
      expect(result.freeText, 'foo:bar landscape');
    });
  });

  group('QueryParser.parse - empty value handling', () {
    test('field with empty value is dropped, not kept as a filter or text', () {
      // Represents in-progress autocomplete state ("from:" typed, value not
      // yet entered) - neither a real constraint nor meaningful search text.
      final result = QueryParser.parse('from: inbox');
      expect(result.hasFilters, isFalse);
      expect(result.freeText, 'inbox');
    });
  });

  group('QueryParser.parse - degenerate input never throws', () {
    test('empty string yields no filters and no free text', () {
      final result = QueryParser.parse('');
      expect(result.filters, isEmpty);
      expect(result.freeText, '');
      expect(result.hasFilters, isFalse);
      expect(result.hasFreeText, isFalse);
    });

    test('whitespace-only string yields no filters and no free text', () {
      final result = QueryParser.parse('   \t  \n ');
      expect(result.filters, isEmpty);
      expect(result.freeText, '');
    });

    test('malformed tokens degrade to free text instead of throwing', () {
      expect(
        () => QueryParser.parse(':::garbage--from:: "unterminated'),
        returnsNormally,
      );
    });
  });

  group('QueryParser.parse - free-text normalization', () {
    test('collapses runs of internal whitespace to single spaces', () {
      final result = QueryParser.parse('sunset    over   the   lake');
      expect(result.freeText, 'sunset over the lake');
    });

    test('trims leading and trailing whitespace', () {
      final result = QueryParser.parse('   sunset lake   ');
      expect(result.freeText, 'sunset lake');
    });
  });

  group('ParsedQuery', () {
    test('raw preserves the original input untouched', () {
      final result = QueryParser.parse('from:bob@x.com  hello  world');
      expect(result.raw, 'from:bob@x.com  hello  world');
    });
  });
}
