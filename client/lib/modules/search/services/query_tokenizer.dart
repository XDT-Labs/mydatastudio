import '../models/search_query.dart';

/// The `field:` names the search grammar recognizes.
///
/// Public because two things read it and they must not drift: [QueryParser],
/// which turns a token into a filter, and the autocomplete dropdown, which has
/// to know whether the caret is sitting in a field it can suggest values for. A
/// field added here becomes parseable and completable in one edit.
const Map<String, FilterField> filterFieldNames = {
  'from': FilterField.from,
  'to': FilterField.to,
  'cc': FilterField.cc,
  'participant': FilterField.participant,
  'subject': FilterField.subject,
  'has': FilterField.has,
  'is': FilterField.is_,
  'type': FilterField.type,
  'after': FilterField.after,
  'before': FilterField.before,
  'in': FilterField.in_,
  'tag': FilterField.tag,
  'near': FilterField.near,
};

bool _isWhitespace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

bool _isAsciiLetter(int code) =>
    (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);

/// One whitespace-delimited piece of a query, with the offsets it occupies.
///
/// [field] is null for a free-text word. The offsets are what separate this
/// from a plain split: autocomplete has to replace *just the value* of the
/// token under the caret, leaving the `from:` prefix and everything around it
/// untouched.
class QueryToken {
  /// Start of the whole token, including any leading `-` and the field name.
  final int start;

  /// One past the end of the whole token, including a closing quote.
  final int end;

  final bool negated;

  /// Null when this is a free-text word rather than a `field:value` token.
  final FilterField? field;

  /// The field name as typed, lowercased. Null for free text.
  final String? fieldName;

  /// The value text, unquoted. For free text, the word itself.
  final String text;

  /// Start of [text] within the query — after the opening quote, if quoted.
  final int valueStart;

  /// One past the end of [text] — before the closing quote, if quoted.
  final int valueEnd;

  final bool quoted;

  const QueryToken({
    required this.start,
    required this.end,
    required this.negated,
    required this.field,
    required this.fieldName,
    required this.text,
    required this.valueStart,
    required this.valueEnd,
    required this.quoted,
  });
}

/// Splits raw search text into tokens, without interpreting any of them.
///
/// Split out from [QueryParser] so the parser and the autocomplete dropdown
/// share one definition of the grammar. Duplicating the scan would let the two
/// disagree about where a value starts — and the disagreement would be silent,
/// showing suggestions for a token the parser reads differently, or replacing
/// the wrong span of text when one is accepted.
class QueryTokenizer {
  static List<QueryToken> scan(String input) {
    final tokens = <QueryToken>[];
    final len = input.length;
    var i = 0;

    while (i < len) {
      while (i < len && _isWhitespace(input.codeUnitAt(i))) {
        i++;
      }
      if (i >= len) break;

      final start = i;
      var j = i;
      final negated = input[j] == '-';
      if (negated) j++;

      final idStart = j;
      while (j < len && _isAsciiLetter(input.codeUnitAt(j))) {
        j++;
      }
      final identifier = input.substring(idStart, j).toLowerCase();
      final field = filterFieldNames[identifier];

      if (field != null && j < len && input[j] == ':') {
        var k = j + 1;
        final quoted = k < len && input[k] == '"';
        if (quoted) k++;
        final valueStart = k;
        if (quoted) {
          while (k < len && input[k] != '"') {
            k++;
          }
        } else {
          while (k < len && !_isWhitespace(input.codeUnitAt(k))) {
            k++;
          }
        }
        final valueEnd = k;
        if (quoted && k < len) k++; // skip closing quote

        tokens.add(
          QueryToken(
            start: start,
            end: k,
            negated: negated,
            field: field,
            fieldName: identifier,
            text: input.substring(valueStart, valueEnd),
            valueStart: valueStart,
            valueEnd: valueEnd,
            quoted: quoted,
          ),
        );
        i = k;
        continue;
      }

      // Not a recognized field:value token — the whole whitespace-delimited
      // word is free text, unknown-field tokens included.
      var k = start;
      while (k < len && !_isWhitespace(input.codeUnitAt(k))) {
        k++;
      }
      tokens.add(
        QueryToken(
          start: start,
          end: k,
          negated: false,
          field: null,
          fieldName: null,
          text: input.substring(start, k),
          valueStart: start,
          valueEnd: k,
          quoted: false,
        ),
      );
      i = k;
    }

    return tokens;
  }

  /// The `field:value` token whose *value* the caret sits in, or null.
  ///
  /// Both ends count as inside, and that is the point rather than an
  /// off-by-one: `from:|` with nothing typed yet is the case the plan calls
  /// out as most useful — it opens the list of top correspondents before the
  /// user has typed a character. A caret inside the field name itself
  /// (`fr|om:bob`) returns null, because the user is editing which field they
  /// mean, not its value.
  static QueryToken? fieldTokenAt(String input, int caret) {
    if (caret < 0 || caret > input.length) return null;
    for (final token in scan(input)) {
      if (token.field == null) continue;
      if (caret >= token.valueStart && caret <= token.valueEnd) return token;
    }
    return null;
  }

  /// [input] with [token]'s value replaced by [value], and where the caret
  /// should land afterwards.
  ///
  /// Quotes the value when it contains whitespace, since an unquoted space
  /// would end the token and turn the rest of the suggestion into free text —
  /// picking the tag `black and white` would otherwise search for `and white`
  /// as loose words. Any `"` inside the value is dropped: the grammar ends a
  /// quoted value at the first quote, so there is no escape to preserve it
  /// with, and silently truncating the value there would be worse.
  static ({String text, int caret}) applySuggestion(
    String input,
    QueryToken token,
    String value,
  ) {
    final cleaned = value.replaceAll('"', '');
    final needsQuotes = cleaned.codeUnits.any(_isWhitespace);
    final inserted = needsQuotes ? '"$cleaned"' : cleaned;

    // Replace from the colon onward so an existing opening quote is consumed
    // rather than left stranded in front of the new value.
    final replaceFrom = token.quoted ? token.valueStart - 1 : token.valueStart;

    // A completion at the very end of the query gets a trailing space, so the
    // next thing typed starts a new term instead of extending the address that
    // was just accepted. Mid-query there is already whitespace to the right.
    final atEnd = token.end >= input.length;
    final suffix = atEnd ? ' ' : '';

    final text =
        input.substring(0, replaceFrom) +
        inserted +
        suffix +
        input.substring(token.end);
    return (text: text, caret: replaceFrom + inserted.length + suffix.length);
  }
}
