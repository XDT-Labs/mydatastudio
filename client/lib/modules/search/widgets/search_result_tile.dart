import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';

/// One ranked hit, rendered the same whether it came from mail or files.
///
/// [SearchResult] already flattens the source-specific shape, so this widget
/// only has to branch on [SearchResult.type] for the leading icon — title,
/// subtitle and snippet all mean the same thing ("what", "where", "why") for
/// both kinds.
///
/// The row follows the Photos module's list view (`PhotoListView`): hover
/// highlight, a 3px accent bar down the left of the selected row, a hairline
/// bottom rule instead of a separate divider, then content / date / actions
/// columns. Two things it deliberately does *not* copy are the sortable column
/// header and the checkbox: results are ordered by relevance, and a header that
/// looks sortable would promise a re-sort that would destroy the ranking.
class SearchResultTile extends StatefulWidget {
  const SearchResultTile({
    super.key,
    required this.result,
    this.onTap,
    this.onDoubleTap,
    this.onExpand,
    this.isSelected = false,
  });

  final SearchResult result;

  /// Selects the row and opens its detail sidebar.
  final VoidCallback? onTap;

  /// Opens the full-size viewer — the lightbox for a file, the reader for mail.
  /// Same destination the spacebar reaches from the selected row.
  final VoidCallback? onDoubleTap;

  /// Same as [onDoubleTap], wired to the explicit button so the gesture is
  /// discoverable without having to guess at it.
  final VoidCallback? onExpand;

  final bool isSelected;

  /// Edge of the square thumbnail.
  ///
  /// Larger than the 40px the Photos list uses, because this list is how the
  /// relevance of a semantic image search gets judged: at 40px a white swan and
  /// a white dog are the same smudge, and telling them apart meant opening
  /// every hit. Stored thumbnails are 320x240, so this is still downscaling.
  static const double thumbnailSize = 100;

  static final DateFormat _dateFormat = DateFormat('MMM d, yyyy');

  @override
  State<SearchResultTile> createState() => _SearchResultTileState();
}

class _SearchResultTileState extends State<SearchResultTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final result = widget.result;

    final backgroundColor =
        widget.isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.15)
            : (_isHovered
                ? colorScheme.surfaceContainerHigh
                : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            color: backgroundColor,
            border: Border(
              left: BorderSide(
                color:
                    widget.isSelected
                        ? colorScheme.primary
                        : Colors.transparent,
                width: 3,
              ),
              bottom: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Leading(result: result, colorScheme: colorScheme),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (result.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        result.subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (result.snippet != null &&
                        result.snippet!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        result.snippet!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        // The taller row leaves space for a third line, and the
                        // snippet is the only thing on screen explaining why a
                        // vector-only hit matched at all.
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(
                width: 140,
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        result.date == null
                            ? '—'
                            : SearchResultTile._dateFormat.format(result.date!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 80,
                // FittedBox for the same reason the Photos list view uses one:
                // an IconButton keeps its 48px tap target regardless of the
                // constraints passed to it, so a fixed-width actions column
                // overflows without one.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.info_outline,
                          color: colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                        onPressed: widget.onTap,
                        tooltip: 'Details',
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        icon: Icon(
                          Icons.open_in_full,
                          color: colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                        onPressed: widget.onExpand ?? widget.onDoubleTap,
                        tooltip: result.isEmail ? 'Read' : 'Expand',
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thumbnail for a file when one exists, otherwise an icon keyed off
/// [SearchResult.type] / [SearchResult.contentType] — emails never have a
/// thumbnail, so the icon path is the only one they take.
class _Leading extends StatelessWidget {
  const _Leading({required this.result, required this.colorScheme});

  final SearchResult result;
  final ColorScheme colorScheme;

  IconData get _icon {
    if (result.isEmail) return Icons.mail_outline;
    final contentType = result.contentType;
    if (contentType == null) return Icons.insert_drive_file_outlined;
    if (contentType == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (contentType.contains('csv') || contentType.contains('spreadsheet')) {
      return Icons.table_chart_outlined;
    }
    if (contentType.contains('zip') ||
        contentType.contains('archive') ||
        contentType.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    if (contentType.startsWith('image/')) return Icons.image_outlined;
    if (contentType.startsWith('video/')) return Icons.movie_outlined;
    if (contentType.startsWith('audio/')) return Icons.audiotrack_outlined;
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final thumbnail = result.isFile ? result.thumbnail : null;
    final imageProvider = ThumbnailResolver.providerFor(thumbnail);

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: SearchResultTile.thumbnailSize,
        height: SearchResultTile.thumbnailSize,
        child:
            imageProvider != null
                ? Image(
                  image: imageProvider,
                  fit: BoxFit.cover,
                  errorBuilder: (ctx, err, stack) => _fallback(),
                )
                : _fallback(),
      ),
    );
  }

  Widget _fallback() {
    return Container(
      color: colorScheme.surfaceContainerHigh,
      child: Center(
        child: Icon(_icon, color: colorScheme.onSurfaceVariant, size: 36),
      ),
    );
  }
}
