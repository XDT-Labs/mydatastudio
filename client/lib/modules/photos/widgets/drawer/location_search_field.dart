import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/models/tables/gazetteer_place.dart';
import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';
import 'package:mydatastudio/repositories/gazetteer_repository.dart';

/// The drawer's Locations control: type a city, pick it, see the photos taken
/// around it.
///
/// This replaced a list of AI-detected landmarks that was empty for everyone —
/// the vision model only ever names a place when a famous one is in frame,
/// while the scanners read a lat/lng out of EXIF for a large share of photos.
/// Searching a place list and filtering on those coordinates is what turns the
/// data that actually exists into something browsable.
class LocationSearchField extends StatefulWidget {
  const LocationSearchField({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.onCleared,
    this.repository,
  });

  /// The place currently filtering the grid, if any.
  final PhotoPlaceFilter? selected;

  final ValueChanged<PhotoPlaceFilter> onSelected;
  final VoidCallback onCleared;

  /// Injected in tests to avoid touching the database.
  final GazetteerRepository? repository;

  @override
  State<LocationSearchField> createState() => _LocationSearchFieldState();
}

class _LocationSearchFieldState extends State<LocationSearchField> {
  late final TextEditingController _controller;
  Timer? _debounce;
  List<GazetteerPlace> _results = [];
  bool _searching = false;

  /// Rises with every query so a slow one landing after a faster later one
  /// cannot overwrite the newer results.
  int _generation = 0;

  GazetteerRepository get _repo => widget.repository ?? GazetteerRepository();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _results = [];
        _searching = false;
      });
      return;
    }
    // Every keystroke would otherwise be a LIKE against 70k rows.
    _debounce = Timer(const Duration(milliseconds: 200), () => _search(query));
  }

  Future<void> _search(String query) async {
    final generation = ++_generation;
    setState(() => _searching = true);

    List<GazetteerPlace> places = [];
    try {
      places = await _repo.search(query, limit: 8);
    } catch (_) {
      // Seeding or the query failed; an empty result set is the honest answer.
    }

    if (!mounted || generation != _generation) return;
    setState(() {
      _results = places;
      _searching = false;
    });
  }

  void _select(GazetteerPlace place) {
    _controller.clear();
    setState(() {
      _results = [];
      _searching = false;
    });
    widget.onSelected(
      PhotoPlaceFilter(
        label: place.label,
        latitude: place.latitude,
        longitude: place.longitude,
        radiusKm: widget.selected?.radiusKm ?? PhotoPlaceFilter.defaultRadiusKm,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = widget.selected;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface,
            ),
            decoration: InputDecoration(
              hintText: 'Search a city...',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 16),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
              suffixIcon:
                  _searching
                      ? const Padding(
                        padding: EdgeInsets.all(10.0),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                      : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 8,
              ),
              border: const OutlineInputBorder(),
            ),
            onChanged: _onQueryChanged,
          ),

          if (_results.isNotEmpty) ...[
            const SizedBox(height: 4),
            Material(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children:
                    _results.map((place) {
                      return InkWell(
                        onTap: () => _select(place),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10.0,
                            vertical: 8.0,
                          ),
                          child: Text(
                            place.label,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurface,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    }).toList(),
              ),
            ),
          ],

          if (selected != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.location_on,
                    size: 16,
                    color: colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      selected.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    color: colorScheme.onPrimaryContainer,
                    tooltip: 'Clear location filter',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    onPressed: widget.onCleared,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // The radius itself lives on the bar above the grid — adjusting it
            // is something you do while watching the results change, not from
            // a drawer you had to open to get here.
            Text(
              'Radius: ${selected.nearestMileOption.toStringAsFixed(0)} mi '
              '— adjust above the grid',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
