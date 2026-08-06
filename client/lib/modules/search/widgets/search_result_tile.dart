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
class SearchResultTile extends StatelessWidget {
  const SearchResultTile({super.key, required this.result, this.onTap});

  final SearchResult result;
  final VoidCallback? onTap;

  static final DateFormat _dateFormat = DateFormat('MMM d, yyyy');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        // Generous vertical hit target — this is a mouse-driven desktop list,
        // not a touch target sized for a thumb.
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Leading(result: result, colorScheme: colorScheme),
            const SizedBox(width: 12),
            Expanded(
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
                  if (result.snippet != null && result.snippet!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      result.snippet!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (result.date != null) ...[
              const SizedBox(width: 12),
              Text(
                _dateFormat.format(result.date!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
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
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 40,
        height: 40,
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
        child: Icon(_icon, color: colorScheme.onSurfaceVariant, size: 20),
      ),
    );
  }
}
