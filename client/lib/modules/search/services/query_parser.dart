import '../models/search_query.dart';

const Map<String, FilterField> _fieldNames = {
  'from': FilterField.from,
  'to': FilterField.to,
  'cc': FilterField.cc,
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

const int _defaultNearRadiusKm = 25;
const int _bareYearMin = 1900;
const int _bareYearMax = 2100;

bool _isWhitespace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

bool _isAsciiLetter(int code) =>
    (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);

/// Parses raw search-bar text into hard filters plus a free-text remainder.
///
/// This is a pure function on purpose: search filtering has to run
/// synchronously as the user types, and mixing in any async/db lookup here
/// would turn every keystroke into a race. Anything the grammar can't make
/// sense of degrades to free text rather than throwing — a search box must
/// never surface a parse error to the user, it just searches for less than
/// they meant.
class QueryParser {
  static ParsedQuery parse(String input) {
    final filters = <QueryFilter>[];
    final textWords = <String>[];

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
      final field = _fieldNames[identifier];

      if (field != null && j < len && input[j] == ':') {
        var k = j + 1;
        String value;
        if (k < len && input[k] == '"') {
          k++;
          final valStart = k;
          while (k < len && input[k] != '"') {
            k++;
          }
          value = input.substring(valStart, k);
          if (k < len) k++; // skip closing quote
        } else {
          final valStart = k;
          while (k < len && !_isWhitespace(input.codeUnitAt(k))) {
            k++;
          }
          value = input.substring(valStart, k);
        }
        final end = k;

        final consumed = _tryAddFilter(
          filters,
          field: field,
          value: value,
          negated: negated,
        );
        if (consumed) {
          i = end;
          continue;
        }
        // Field matched but the value didn't hold up (bad date, empty
        // value): the whole token as typed falls back to free text so
        // nothing is silently dropped or half-parsed.
        if (value.isEmpty) {
          // Explicit "drop" case (e.g. `from:` mid-autocomplete) — no
          // filter, no free text.
          i = end;
          continue;
        }
        textWords.add(input.substring(start, end));
        i = end;
        continue;
      }

      // Not a recognized field:value token — the whole whitespace-delimited
      // word is free text, unknown-field tokens included.
      var k = start;
      while (k < len && !_isWhitespace(input.codeUnitAt(k))) {
        k++;
      }
      textWords.add(input.substring(start, k));
      i = k;
    }

    _consumeBareYear(filters, textWords);

    return ParsedQuery(
      filters: filters,
      freeText: textWords.join(' '),
      raw: input,
    );
  }

  /// Returns true if [value] produced a filter (added to [filters]).
  /// Returns false for fields whose value failed validation (bad date) or
  /// was empty — the caller decides what to do with the raw token in each
  /// case since that differs by field.
  static bool _tryAddFilter(
    List<QueryFilter> filters, {
    required FilterField field,
    required String value,
    required bool negated,
  }) {
    if (field == FilterField.after || field == FilterField.before) {
      final date = _parseFilterDate(value);
      if (date == null) return false;
      filters.add(
        QueryFilter(
          field: field,
          value: value,
          dateValue: date,
          negated: negated,
        ),
      );
      return true;
    }

    if (field == FilterField.near) {
      if (value.isEmpty) return false;
      final lastColon = value.lastIndexOf(':');
      var place = value;
      var radius = _defaultNearRadiusKm;
      if (lastColon > 0 && lastColon < value.length - 1) {
        final radiusText = value.substring(lastColon + 1);
        final parsedRadius = int.tryParse(radiusText);
        if (parsedRadius != null && parsedRadius > 0) {
          place = value.substring(0, lastColon);
          radius = parsedRadius;
        }
      }
      filters.add(
        QueryFilter(
          field: field,
          value: place,
          radiusKm: radius,
          negated: negated,
        ),
      );
      return true;
    }

    // Plain string fields: from, to, cc, subject, has, is_, type, in_, tag.
    if (value.isEmpty) return false;
    filters.add(QueryFilter(field: field, value: value, negated: negated));
    return true;
  }

  static DateTime? _parseFilterDate(String value) {
    final full = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (full != null) {
      final y = int.parse(full.group(1)!);
      final m = int.parse(full.group(2)!);
      final d = int.parse(full.group(3)!);
      if (m < 1 || m > 12) return null;
      final daysInMonth = DateTime(y, m + 1, 0).day;
      if (d < 1 || d > daysInMonth) return null;
      return DateTime(y, m, d);
    }

    final yearMonth = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(value);
    if (yearMonth != null) {
      final y = int.parse(yearMonth.group(1)!);
      final m = int.parse(yearMonth.group(2)!);
      if (m < 1 || m > 12) return null;
      return DateTime(y, m, 1);
    }

    final yearOnly = RegExp(r'^(\d{4})$').firstMatch(value);
    if (yearOnly != null) {
      return DateTime(int.parse(yearOnly.group(1)!), 1, 1);
    }

    return null;
  }

  /// A standalone 4-digit word in free text implies an `after`/`before`
  /// range spanning that year, so `photos from 2026` filters like
  /// `after:2026 before:2027` without the user learning the field syntax.
  /// Only fires when there's no explicit after/before already, and only
  /// consumes the first such word — later ones are ambiguous enough (could
  /// be a model number, a count) that guessing past the first is more
  /// likely to surprise than help.
  static void _consumeBareYear(
    List<QueryFilter> filters,
    List<String> textWords,
  ) {
    final hasExplicitDateFilter = filters.any(
      (f) => f.field == FilterField.after || f.field == FilterField.before,
    );
    if (hasExplicitDateFilter) return;

    final yearPattern = RegExp(r'^\d{4}$');
    for (var idx = 0; idx < textWords.length; idx++) {
      final word = textWords[idx];
      if (!yearPattern.hasMatch(word)) continue;
      final year = int.parse(word);
      if (year < _bareYearMin || year > _bareYearMax) continue;

      filters.add(
        QueryFilter(
          field: FilterField.after,
          value: word,
          dateValue: DateTime(year, 1, 1),
        ),
      );
      filters.add(
        QueryFilter(
          field: FilterField.before,
          value: word,
          dateValue: DateTime(year + 1, 1, 1),
        ),
      );
      textWords.removeAt(idx);
      return;
    }
  }
}
