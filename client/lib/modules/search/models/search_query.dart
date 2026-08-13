/// `is` and `in` are Dart reserved words, so the values that spell them in
/// query text (`is:unread`, `in:"Work Gmail"`) are represented as `is_`/`in_`.
enum FilterField {
  from,
  to,
  cc,

  /// Anyone on the message, in any role — sender, recipient or copied.
  ///
  /// What `with` and `between` mean. Correspondence is bidirectional and a
  /// thread alternates direction with every reply, so "my emails with Sarah"
  /// cannot be expressed as `from:` or `to:` without losing half the thread.
  participant,

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

  /// Centre point for a [FilterField.near] filter, once a gazetteer lookup has
  /// found one. Null until then, and null forever for a place name the
  /// gazetteer does not carry.
  ///
  /// Parsing is deterministic and synchronous; resolving a name to coordinates
  /// is a database query. Keeping the result on the filter rather than in a
  /// parallel structure means the retriever still takes a [ParsedQuery], and
  /// there is no way to hand it a query whose geo terms were never resolved.
  final double? latitude;
  final double? longitude;

  /// How the resolved place is shown back to the user — "Banff, CA" — so a
  /// chip can say which of several namesakes was picked.
  final String? placeLabel;

  /// The words in the raw query this filter was derived from, for filters that
  /// no `field:value` token produced — today, the `from mike nimer` in
  /// `emails from mike nimer`. Null for anything the user typed as syntax.
  ///
  /// Needed because removing a chip works by deleting the token it came from.
  /// A resolved filter's value is an address that appears nowhere in the raw
  /// text, so without this the delete silently matches nothing and the chip
  /// looks broken — it stays on screen and the same results come back.
  final String? sourceText;

  const QueryFilter({
    required this.field,
    required this.value,
    this.dateValue,
    this.radiusKm,
    this.negated = false,
    this.latitude,
    this.longitude,
    this.placeLabel,
    this.sourceText,
  });

  /// True when a resolution pass inferred this from prose rather than the user
  /// typing `field:value`.
  bool get isInferred => sourceText != null;

  /// This filter with a gazetteer hit attached.
  QueryFilter resolvedTo({
    required double latitude,
    required double longitude,
    required String placeLabel,
  }) {
    return QueryFilter(
      field: field,
      value: value,
      dateValue: dateValue,
      radiusKm: radiusKm,
      negated: negated,
      latitude: latitude,
      longitude: longitude,
      placeLabel: placeLabel,
      sourceText: sourceText,
    );
  }

  /// Whether this filter carries a centre point to measure a radius from.
  bool get hasCoordinates => latitude != null && longitude != null;

  @override
  bool operator ==(Object other) {
    return other is QueryFilter &&
        other.field == field &&
        other.value == value &&
        other.dateValue == dateValue &&
        other.radiusKm == radiusKm &&
        other.negated == negated &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.placeLabel == placeLabel &&
        other.sourceText == sourceText;
  }

  @override
  int get hashCode => Object.hash(
    field,
    value,
    dateValue,
    radiusKm,
    negated,
    latitude,
    longitude,
    placeLabel,
    sourceText,
  );

  @override
  String toString() {
    final sign = negated ? '-' : '';
    final buf = StringBuffer('$sign${field.name}:$value');
    if (dateValue != null) buf.write(' (date=$dateValue)');
    if (radiusKm != null) buf.write(' (radiusKm=$radiusKm)');
    if (hasCoordinates) buf.write(' (@$latitude,$longitude)');
    return buf.toString();
  }
}

/// Result of parsing one raw search string: structured filters plus
/// whatever text didn't parse into a filter.
class ParsedQuery {
  final List<QueryFilter> filters;
  final String freeText;
  final String raw;

  /// Kinds of thing the query *named* — "photos", "emails" — as `type:` values.
  ///
  /// Deliberately not a filter. Naming a kind expresses a preference about
  /// order, not a constraint on membership: someone searching "family photos"
  /// wants the photographs first but still wants the thread those photos were
  /// sent in, and still needs the Emails facet to hold something when they
  /// click it. A `type:` filter would zero that facet out and turn it into a
  /// dead end.
  ///
  /// An *explicit* `type:image` is a different statement and stays a real
  /// filter — that is the user being specific rather than the parser guessing.
  final Set<String> preferredTypes;

  const ParsedQuery({
    required this.filters,
    required this.freeText,
    required this.raw,
    this.preferredTypes = const {},
  });

  /// Whether [type] is one the query asked to see first. Null when the query
  /// named no kind at all — which is not the same as naming one and missing.
  bool? prefers(String type) {
    if (preferredTypes.isEmpty) return null;
    return preferredTypes.contains(type);
  }

  bool get hasFilters => filters.isNotEmpty;
  bool get hasFreeText => freeText.isNotEmpty;

  /// [raw] is deliberately not replaceable: it is what the user typed, and it
  /// is what re-running the search has to start from. A resolution pass that
  /// rewrote it would make the query in the search box drift away from the
  /// query in the URL.
  ParsedQuery copyWith({List<QueryFilter>? filters, String? freeText}) {
    return ParsedQuery(
      filters: filters ?? this.filters,
      freeText: freeText ?? this.freeText,
      raw: raw,
      preferredTypes: preferredTypes,
    );
  }

  /// This query with an inferred modality preference attached.
  ///
  /// Separate from [copyWith] because it is a different kind of act: the
  /// planner is guessing, and a guess must only ever fill a silence. Applied
  /// to a query that already named a kind it would overwrite what the user
  /// actually said, so callers gate on [QueryPlanner.isAmbiguous] — this only
  /// makes that impossible to do by accident by being impossible to miss.
  ParsedQuery withPreferredTypes(Set<String> types) {
    return ParsedQuery(
      filters: filters,
      freeText: freeText,
      raw: raw,
      preferredTypes: types,
    );
  }

  /// A field may repeat (`from:a from:b`); callers OR these together rather
  /// than treating the second as overriding the first.
  List<QueryFilter> filtersFor(FilterField f) {
    return filters.where((filter) => filter.field == f).toList();
  }
}
