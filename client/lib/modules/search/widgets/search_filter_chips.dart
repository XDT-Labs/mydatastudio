import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';

/// Renders [ParsedQuery.filters] as removable chips.
///
/// Mirrors the `field:value` shape the user typed rather than a friendlier
/// paraphrase — the chip is meant to read as "this is the constraint you set"
/// so removing it and re-reading the search box match up.
class SearchFilterChips extends StatelessWidget {
  const SearchFilterChips({super.key, required this.filters, this.onRemove});

  final List<QueryFilter> filters;
  final ValueChanged<QueryFilter>? onRemove;

  static final DateFormat _dateFormat = DateFormat('yyyy-MM-dd');

  /// `is_`/`in_` exist only to dodge Dart reserved words — the user never
  /// typed the trailing underscore, so the chip must not show it either.
  ///
  /// Public: [SearchPage] reconstructs the same token to strip a filter out
  /// of the raw query text when its chip is removed.
  static String fieldName(FilterField field) {
    switch (field) {
      case FilterField.is_:
        return 'is';
      case FilterField.in_:
        return 'in';
      default:
        return field.name;
    }
  }

  static String _labelFor(QueryFilter filter) {
    String value = filter.value;
    if ((filter.field == FilterField.after ||
            filter.field == FilterField.before) &&
        filter.dateValue != null) {
      value = _dateFormat.format(filter.dateValue!);
    }

    final sign = filter.negated ? '-' : '';
    final label = '$sign${fieldName(filter.field)}:$value';

    if (filter.field == FilterField.near && filter.radiusKm != null) {
      return '$label (${filter.radiusKm}km)';
    }
    return label;
  }

  @override
  Widget build(BuildContext context) {
    if (filters.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children:
          filters.map((filter) {
            return InputChip(
              label: Text(_labelFor(filter)),
              labelStyle: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
              ),
              backgroundColor: colorScheme.secondaryContainer,
              shape: const StadiumBorder(),
              side: BorderSide.none,
              deleteIcon: const Icon(Icons.close, size: 16),
              onDeleted: onRemove == null ? null : () => onRemove!(filter),
            );
          }).toList(),
    );
  }
}
