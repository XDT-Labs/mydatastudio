import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';

/// Keyboard shortcuts dialog listing shortcut keys and descriptions.
class KeyboardShortcutsModal extends StatelessWidget {
  const KeyboardShortcutsModal({super.key});

  static const List<({String keyLabel, String actionLabel})> _shortcuts = [
    (keyLabel: 'Space', actionLabel: 'View photo fullscreen'),
    (keyLabel: 'I', actionLabel: 'Toggle info sidebar'),
    (keyLabel: 'Escape', actionLabel: 'Close viewer/sidebar/modal'),
    (keyLabel: '← / →', actionLabel: 'Previous/Next photo'),
    (keyLabel: '+ / =', actionLabel: 'Zoom in'),
    (keyLabel: '-', actionLabel: 'Zoom out'),
    (keyLabel: 'F', actionLabel: 'Toggle favorite'),
    (keyLabel: 'Delete', actionLabel: 'Delete selected'),
    (keyLabel: 'Ctrl+A', actionLabel: 'Select all'),
    (keyLabel: '?', actionLabel: 'Show this help'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return AlertDialog(
      backgroundColor: colorScheme.surfaceContainer,
      title: Row(
        children: [
          Icon(Icons.keyboard_outlined, color: colorScheme.primary),
          const SizedBox(width: 12),
          Text(
            'Keyboard Shortcuts',
            style: textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _shortcuts.map((shortcut) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6.0),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 4.0,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(4.0),
                        border: Border.all(
                          color: colorScheme.outlineVariant,
                        ),
                      ),
                      child: Text(
                        shortcut.keyLabel,
                        style: GoogleFonts.robotoMono(
                          textStyle: textTheme.labelMedium,
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        shortcut.actionLabel,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Close',
            style: TextStyle(color: colorScheme.primary),
          ),
        ),
      ],
    );
  }
}
