import 'package:flutter/material.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';

/// Which slice of an already-fetched result set is on screen.
enum SearchFacet { all, email, file }

/// Applies [facet] to [results] in memory.
///
/// The counts on [SearchFacetBar] come from the same query that produced
/// [results] ([SearchResults.emailCount]/[fileCount]), so switching facets
/// only needs to re-slice what's already loaded — re-querying per facet
/// would just re-derive numbers the result set already carries.
List<SearchResult> filterResultsByFacet(
  List<SearchResult> results,
  SearchFacet facet,
) {
  switch (facet) {
    case SearchFacet.all:
      return results;
    case SearchFacet.email:
      return results.where((r) => r.isEmail).toList();
    case SearchFacet.file:
      return results.where((r) => r.isFile).toList();
  }
}

/// Type-count tabs above the result list: All / Emails / Photos & Files.
class SearchFacetBar extends StatelessWidget {
  const SearchFacetBar({
    super.key,
    required this.total,
    required this.emailCount,
    required this.fileCount,
    required this.selected,
    required this.onSelected,
  });

  final int total;
  final int emailCount;
  final int fileCount;
  final SearchFacet selected;
  final ValueChanged<SearchFacet> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _FacetChip(
          label: 'All',
          count: total,
          facet: SearchFacet.all,
          selected: selected,
          onSelected: onSelected,
        ),
        _FacetChip(
          label: 'Emails',
          count: emailCount,
          facet: SearchFacet.email,
          selected: selected,
          onSelected: onSelected,
        ),
        _FacetChip(
          label: 'Photos & Files',
          count: fileCount,
          facet: SearchFacet.file,
          selected: selected,
          onSelected: onSelected,
        ),
      ],
    );
  }
}

class _FacetChip extends StatelessWidget {
  const _FacetChip({
    required this.label,
    required this.count,
    required this.facet,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final int count;
  final SearchFacet facet;
  final SearchFacet selected;
  final ValueChanged<SearchFacet> onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = selected == facet;

    return ChoiceChip(
      label: Text('$label $count'),
      selected: isSelected,
      onSelected: (_) => onSelected(facet),
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: colorScheme.surfaceContainerHigh,
      selectedColor: colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color:
            isSelected
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurfaceVariant,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }
}
