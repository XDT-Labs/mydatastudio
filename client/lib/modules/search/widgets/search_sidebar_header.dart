import 'package:flutter/material.dart';

/// The title bar both search detail sidebars wear.
///
/// Matches the Files module's `FileDetailsDrawer` header — same 13pt bold
/// label, same icon-then-title order, same width toggle and close on the right —
/// so a panel opened from search reads as the same piece of furniture the user
/// already knows from the Files and Photos modules.
class SearchSidebarHeader extends StatelessWidget {
  const SearchSidebarHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.onClose,
    this.onToggleWidth,
    this.isWide = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onClose;
  final VoidCallback? onToggleWidth;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          if (onToggleWidth != null)
            IconButton(
              icon: Icon(
                isWide ? Icons.close_fullscreen : Icons.open_in_full,
                size: 16,
              ),
              tooltip: isWide ? 'Restore Width' : 'Maximize Width',
              onPressed: onToggleWidth,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
            ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close',
            onPressed: onClose,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
