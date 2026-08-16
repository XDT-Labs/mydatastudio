import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';

/// The strip under the toolbar showing which place the grid is filtered to,
/// with the radius on a slider.
///
/// The radius belongs here rather than beside the search box in the drawer:
/// picking a distance is a thing you do *while looking at the results*, and
/// widening from a few miles to a few dozen is how you find out where a
/// library's photos actually cluster. Tucked into the drawer it was neither
/// visible nor obviously connected to what the grid was showing.
class PlaceFilterBar extends StatelessWidget {
  const PlaceFilterBar({
    super.key,
    this.place,
    this.landmark,
    required this.onRadiusChanged,
    required this.onCleared,
    this.matchCount,
  }) : assert(place != null || landmark != null);

  /// A gazetteer place, filtered by distance from its coordinates.
  final PhotoPlaceFilter? place;

  /// A landmark name recognised by the image analysis. Filtered by name
  /// rather than distance, so it has no radius to adjust — but it is still a
  /// location filter, and hiding it here left the user with a narrowed grid
  /// and nothing on screen saying why.
  final String? landmark;

  /// Reports the new radius in miles.
  final ValueChanged<double> onRadiusChanged;

  final VoidCallback onCleared;

  /// How many photos the current radius matches, when known.
  final int? matchCount;

  static String formatMiles(double miles) {
    final rounded = miles.round();
    return '$rounded ${rounded == 1 ? 'mile' : 'miles'}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final options = PhotoPlaceFilter.radiusMileOptions;
    final current = place?.nearestMileOption ?? 0;
    final index = options.indexOf(current).clamp(0, options.length - 1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(
            place != null ? Icons.location_on : Icons.photo_camera_outlined,
            size: 16,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              place?.label ?? landmark!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Says why there is no radius here. The two location filters look
          // alike and behave nothing alike: this one matches a name the image
          // analysis recognised, on photos that mostly carry no coordinates at
          // all, so there is no point to measure a distance from.
          if (place == null) ...[
            const SizedBox(width: 8),
            Tooltip(
              message:
                  'Matched by what the photo shows, not by GPS — '
                  'so there is no distance to widen.',
              child: Text(
                'recognised in photo',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
          // A landmark match has no distance to widen, so the slider would be
          // a control that does nothing.
          if (place != null) ...[
            const SizedBox(width: 16),
            Text(
              'Within',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(
              width: 150,
              child: Slider(
                value: index.toDouble(),
                min: 0,
                max: (options.length - 1).toDouble(),
                divisions: options.length - 1,
                label: formatMiles(options[index]),
                onChanged: (value) => onRadiusChanged(options[value.round()]),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                formatMiles(current),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (matchCount != null) ...[
            const SizedBox(width: 8),
            // Flexible, because the empty-result message is long enough to
            // push the Clear button off a narrow window otherwise.
            Flexible(
              child: Text(
                matchCount != 0
                    ? '$matchCount ${matchCount == 1 ? 'photo' : 'photos'}'
                    // The most common reason a place comes back empty, and not
                    // guessable from an empty grid: most photos carry no
                    // coordinates at all, so no radius will ever reach them.
                    // A landmark match does not work that way.
                    : place != null
                    ? 'No geotagged photos here — try a wider radius'
                    : 'No photos',
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      matchCount == 0
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const Spacer(),
          TextButton.icon(
            onPressed: onCleared,
            icon: const Icon(Icons.close, size: 16),
            label: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}
