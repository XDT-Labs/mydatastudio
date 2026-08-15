import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/query_tokenizer.dart';

/// The caret position marked by `|` in [marked], with the marker removed.
({String text, int caret}) _at(String marked) {
  final caret = marked.indexOf('|');
  return (text: marked.replaceFirst('|', ''), caret: caret);
}

QueryToken? _tokenAt(String marked) {
  final input = _at(marked);
  return QueryTokenizer.fieldTokenAt(input.text, input.caret);
}

void main() {
  group('QueryTokenizer.fieldTokenAt — which field the caret is editing', () {
    test('caret inside a value reports that field and what is typed so far', () {
      final token = _tokenAt('from:mi|');
      expect(token?.field, FilterField.from);
      expect(token?.text, 'mi');
    });

    test('caret straight after the colon opens the field with no value yet', () {
      // The plan's most useful case: `from:` with nothing typed shows top
      // correspondents by volume, before the user commits to any characters.
      final token = _tokenAt('from:|');
      expect(token?.field, FilterField.from);
      expect(token?.text, isEmpty);
    });

    test('caret inside the field name suggests nothing', () {
      // The user is deciding *which* field they mean. Offering values for a
      // half-typed field name would suggest against a field they are in the
      // middle of changing.
      expect(_tokenAt('fr|om:bob'), isNull);
    });

    test('free text suggests nothing', () {
      expect(_tokenAt('vacation phot|os'), isNull);
    });

    test('the right field is picked out of several', () {
      final token = _tokenAt('from:bob tag:sunse|t after:2020');
      expect(token?.field, FilterField.tag);
    });

    test('a caret in the middle of a value matches on the whole value', () {
      // Not on the fragment to its left. Filtering `sunset` down to `sun`
      // because the caret happens to sit there would offer suggestions that
      // contradict the word the user can see in the box.
      final token = _tokenAt('tag:sun|set');
      expect(token?.text, 'sunset');
    });

    test('a space after the colon ends the value, so the next word is free '
        'text and not a suggestion for the field', () {
      // `from: bob` means an empty from: plus the word "bob" — the caret in
      // "bob" must not offer contacts, or accepting one would rewrite a word
      // the parser never treated as part of the filter.
      expect(_tokenAt('from: bo|b'), isNull);
    });

    test('caret inside a quoted value reports the unquoted text', () {
      final token = _tokenAt('tag:"black and wh|ite"');
      expect(token?.field, FilterField.tag);
      expect(token?.text, 'black and white');
      expect(token?.quoted, isTrue);
    });

    test('a negated filter still completes', () {
      final token = _tokenAt('-from:sp|am');
      expect(token?.field, FilterField.from);
      expect(token?.negated, isTrue);
    });

    test('an out-of-range caret returns null rather than throwing', () {
      // Controller and text can be momentarily out of step during a rebuild;
      // a search box must never throw on a stale offset.
      expect(QueryTokenizer.fieldTokenAt('from:bob', 99), isNull);
      expect(QueryTokenizer.fieldTokenAt('from:bob', -1), isNull);
    });
  });

  group('QueryTokenizer.applySuggestion — accepting a completion', () {
    test('replaces only the value, leaving the rest of the query alone', () {
      const text = 'from:mi vacation';
      final token = QueryTokenizer.fieldTokenAt(text, 7)!;
      final result = QueryTokenizer.applySuggestion(
        text,
        token,
        'mike@xdtlabs.com',
      );
      expect(result.text, 'from:mike@xdtlabs.com vacation');
      expect(result.caret, 'from:mike@xdtlabs.com'.length);
    });

    test('a value with spaces is quoted, so it stays one filter', () {
      // Unquoted, the space would end the token and "and white" would become
      // free text — the filter would silently mean something else.
      const text = 'tag:bla';
      final token = QueryTokenizer.fieldTokenAt(text, 7)!;
      final result = QueryTokenizer.applySuggestion(
        text,
        token,
        'black and white',
      );
      expect(result.text, 'tag:"black and white" ');
      expect(QueryParser.parse(result.text).filters.single.value,
          'black and white');
    });

    test('completing an already-quoted value does not double its quotes', () {
      const text = 'tag:"bla"';
      final token = QueryTokenizer.fieldTokenAt(text, 8)!;
      final result = QueryTokenizer.applySuggestion(
        text,
        token,
        'black and white',
      );
      expect(result.text, 'tag:"black and white" ');
    });

    test('a completion at the end of the query gets a trailing space', () {
      // So the next keystroke starts a new term instead of extending the
      // address that was just accepted.
      const text = 'from:mi';
      final token = QueryTokenizer.fieldTokenAt(text, 7)!;
      final result = QueryTokenizer.applySuggestion(text, token, 'm@x.com');
      expect(result.text, 'from:m@x.com ');
      expect(result.caret, result.text.length);
    });

    test('a completion mid-query does not add a second space', () {
      const text = 'from:mi vacation';
      final token = QueryTokenizer.fieldTokenAt(text, 7)!;
      final result = QueryTokenizer.applySuggestion(text, token, 'm@x.com');
      expect(result.text, 'from:m@x.com vacation');
    });

    test('the completed query parses to the filter the user picked', () {
      // The whole point of autocomplete per §13: the value that lands in the
      // box is one the parser turns into the exact filter, with no name
      // resolution or guessing in between.
      const text = 'from:mi';
      final token = QueryTokenizer.fieldTokenAt(text, 7)!;
      final result = QueryTokenizer.applySuggestion(
        text,
        token,
        'mike@xdtlabs.com',
      );
      final parsed = QueryParser.parse(result.text);
      expect(parsed.filters.single.field, FilterField.from);
      expect(parsed.filters.single.value, 'mike@xdtlabs.com');
      expect(parsed.freeText, isEmpty);
    });
  });
}
