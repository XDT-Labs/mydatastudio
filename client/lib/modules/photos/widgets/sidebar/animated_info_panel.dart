import 'package:flutter/material.dart';

/// Animated slide-in wrapper widget for the Photos right info panel.
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

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      width: isOpen ? width : 0.0,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
      ),
      clipBehavior: Clip.hardEdge,
      child: OverflowBox(
        minWidth: width,
        maxWidth: width,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: child,
        ),
      ),
    );
  }
}
