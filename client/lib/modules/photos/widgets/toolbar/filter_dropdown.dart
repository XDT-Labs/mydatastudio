import 'package:material_ui/material_ui.dart';

/// Filter dropdown popup menu widget for the Photos module toolbar.
class FilterDropdown extends StatelessWidget {
  const FilterDropdown({
    super.key,
    required this.mediaType,
    required this.onlyFavorites,
    required this.sortBy,
    required this.onMediaTypeChanged,
    required this.onFavoritesChanged,
    required this.onSortChanged,
  });

  final String? mediaType;
  final bool onlyFavorites;
  final String sortBy;
  final ValueChanged<String?> onMediaTypeChanged;
  final ValueChanged<bool> onFavoritesChanged;
  final ValueChanged<String> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final isFiltered = mediaType != null || onlyFavorites || sortBy != 'dateDesc';

    return PopupMenuButton<void>(
      tooltip: 'Filter & Sort',
      color: colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      icon: Icon(
        Icons.filter_list,
        color: isFiltered ? colorScheme.primary : colorScheme.onSurfaceVariant,
      ),
      itemBuilder: (BuildContext context) => [
        // Section: Type
        PopupMenuItem<void>(
          enabled: false,
          child: Text(
            'MEDIA TYPE',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        PopupMenuItem<void>(
          enabled: false,
          child: RadioGroup<String?>(
            groupValue: mediaType,
            onChanged: onMediaTypeChanged,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () {
                    onMediaTypeChanged(null);
                    Navigator.of(context).pop();
                  },
                  child: const Row(
                    children: [
                      Radio<String?>(value: null),
                      SizedBox(width: 8),
                      Text('All'),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () {
                    onMediaTypeChanged('photo');
                    Navigator.of(context).pop();
                  },
                  child: const Row(
                    children: [
                      Radio<String?>(value: 'photo'),
                      SizedBox(width: 8),
                      Text('Photos'),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () {
                    onMediaTypeChanged('video');
                    Navigator.of(context).pop();
                  },
                  child: const Row(
                    children: [
                      Radio<String?>(value: 'video'),
                      SizedBox(width: 8),
                      Text('Videos'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const PopupMenuDivider(),
        // Section: Favorites
        PopupMenuItem<void>(
          onTap: () => onFavoritesChanged(!onlyFavorites),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text('Favorites Only'),
              ),
              Switch(
                value: onlyFavorites,
                onChanged: onFavoritesChanged,
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        // Section: Sort
        PopupMenuItem<void>(
          enabled: false,
          child: Text(
            'SORT BY',
            style: textTheme.labelSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        PopupMenuItem<void>(
          enabled: false,
          child: RadioGroup<String>(
            groupValue: sortBy,
            onChanged: (val) {
              if (val != null) onSortChanged(val);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                (value: 'dateDesc', label: 'Newest'),
                (value: 'dateAsc', label: 'Oldest'),
                (value: 'title', label: 'Title'),
                (value: 'size', label: 'Size'),
              ].map(
                (option) => InkWell(
                  onTap: () {
                    onSortChanged(option.value);
                    Navigator.of(context).pop();
                  },
                  child: Row(
                    children: [
                      Radio<String>(value: option.value),
                      const SizedBox(width: 8),
                      Text(option.label),
                    ],
                  ),
                ),
              ).toList(),
            ),
          ),
        ),
      ],
    );
  }
}
