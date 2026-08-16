import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';

/// Which archive the result list is restricted to.
enum SearchFacet { all, email, file }

/// The source type [facet] restricts retrieval to, or null for everything.
SearchResultType? sourceTypeForFacet(SearchFacet facet) {
  switch (facet) {
    case SearchFacet.all:
      return null;
    case SearchFacet.email:
      return SearchResultType.email;
    case SearchFacet.file:
      return SearchResultType.file;
  }
}

/// Type-count tabs above the result list: All / Emails / Photos & Files.
///
/// Counts are archive totals, not counts of what happens to be loaded. The
/// list pages in as it scrolls, so every match is reachable and reporting the
/// loaded subset would understate the archive to describe an implementation
/// detail. Selecting a facet re-queries that source rather than slicing the
/// loaded rows — otherwise "Photos & Files 1,134" could only ever show the
/// few hundred already fetched alongside the mail.
class SearchFacetBar extends StatelessWidget {
  const SearchFacetBar({
    super.key,
    required this.total,
    required this.emailTotal,
    required this.fileTotal,
    required this.selected,
    required this.onSelected,
  });

  final int total;
  final int emailTotal;
  final int fileTotal;
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
          count: emailTotal,
          facet: SearchFacet.email,
          selected: selected,
          onSelected: onSelected,
        ),
        _FacetChip(
          label: 'Photos & Files',
          count: fileTotal,
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
