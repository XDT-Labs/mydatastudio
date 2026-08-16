import 'package:material_ui/material_ui.dart';

/// Animated slide-in wrapper widget for the Photos right info panel.
///
/// Built on [AnimatedSize] anchored to the top *right*, the same mechanism the
/// Files module's details drawer uses: the panel's right edge stays pinned to
/// the window while the box grows, so it slides in from the edge and pushes
/// the grid aside. Sizing the panel from the left instead — which is what an
/// `AnimatedContainer` + left-aligned `OverflowBox` does — renders the panel in
/// its final position on frame one and then wipes it into view, which reads as
/// the panel appearing on top of the content rather than arriving beside it.
class AnimatedInfoPanel extends StatelessWidget {
  const AnimatedInfoPanel({
    super.key,
    required this.isOpen,
    required this.child,
    this.width = 320.0,
  });

  final bool isOpen;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topRight,
      child:
          isOpen
              ? Container(
                width: width,
                color: colorScheme.surfaceContainer,
                child: child,
              )
              : const SizedBox(width: 0, height: double.infinity),
    );
  }
}
