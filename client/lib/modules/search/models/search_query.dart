/// `is` and `in` are Dart reserved words, so the values that spell them in
/// query text (`is:unread`, `in:"Work Gmail"`) are represented as `is_`/`in_`.
enum FilterField {
  from,
  to,
  cc,
  subject,
  has,
  is_,
  type,
  after,
  before,
  in_,
  tag,
  near,
}

/// One `field:value` constraint pulled out of a raw query string.
///
/// Filters constrain the result set (AND'd across distinct fields, OR'd
/// across repeats of the same field by the caller); everything that isn't a
/// filter becomes free text that ranks rather than excludes results. Keeping
/// that split explicit here is what lets the search layer build a SQL WHERE
/// clause from [filters] and a separate ranking/embedding pass from the
/// remaining text, instead of guessing intent from one blended string.
class QueryFilter {
  final FilterField field;

  /// Raw string form of the value. For [FilterField.after] / [before] this
  /// is the original query text (e.g. `"2026"`), not a formatted date,
  /// because surfacing what the user typed matters more than a canonical
  /// form once [dateValue] already carries the parsed result.
  final String value;
  final DateTime? dateValue;
  final int? radiusKm;
  final bool negated;

  const QueryFilter({
    required this.field,
    required this.value,
    this.dateValue,
    this.radiusKm,
    this.negated = false,
  });

  @override
  bool operator ==(Object other) {
    return other is QueryFilter &&
        other.field == field &&
        other.value == value &&
        other.dateValue == dateValue &&
        other.radiusKm == radiusKm &&
        other.negated == negated;
  }

  @override
  int get hashCode => Object.hash(field, value, dateValue, radiusKm, negated);

  @override
  String toString() {
    final sign = negated ? '-' : '';
    final buf = StringBuffer('$sign${field.name}:$value');
    if (dateValue != null) buf.write(' (date=$dateValue)');
    if (radiusKm != null) buf.write(' (radiusKm=$radiusKm)');
    return buf.toString();
  }
}

/// Result of parsing one raw search string: structured filters plus
/// whatever text didn't parse into a filter.
class ParsedQuery {
  final List<QueryFilter> filters;
  final String freeText;
  final String raw;

  const ParsedQuery({
    required this.filters,
    required this.freeText,
    required this.raw,
  });

  bool get hasFilters => filters.isNotEmpty;
  bool get hasFreeText => freeText.isNotEmpty;

  /// A field may repeat (`from:a from:b`); callers OR these together rather
  /// than treating the second as overriding the first.
  List<QueryFilter> filtersFor(FilterField f) {
    return filters.where((filter) => filter.field == f).toList();
  }
}
