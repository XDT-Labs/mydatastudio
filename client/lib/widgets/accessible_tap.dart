import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A keyboard-operable, screen-reader-labeled tap target — the accessible
/// replacement for the `Semantics(button: true) + GestureDetector` pattern the
/// app uses for custom (non-Material-button) controls (AUDIT M4).
///
/// Beyond what a bare [GestureDetector] offers, this adds the two things that
/// pattern was missing for WCAG 2.2 AA:
///   * keyboard focus + Enter/Space activation (2.1.1 Keyboard), and
///   * a focus ring drawn over the child on keyboard focus (2.4.7 Focus
///     Visible),
/// while leaving the child's own visuals untouched — no Material ink ripple, so
/// the control looks identical to today until it is focused via the keyboard.
class AccessibleTap extends StatefulWidget {
  const AccessibleTap({
    super.key,
    required this.onPressed,
    required this.label,
    required this.child,
    this.enabled = true,
    this.selected,
    this.expanded,
    this.tooltip,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.mergeSemantics = true,
    this.autofocus = false,
  });

  /// Invoked on tap and on keyboard activation. A null callback (or
  /// [enabled] == false) makes the control non-focusable and announces it as a
  /// disabled button.
  final VoidCallback? onPressed;

  /// The accessible name announced by assistive tech.
  final String label;

  final Widget child;

  final bool enabled;

  /// Selected state for toggle-like controls (nav items, conversation tiles).
  final bool? selected;

  /// Expanded state for disclosure controls (accordion headers).
  final bool? expanded;

  /// Pointer-only hover hint. The accessible name always comes from [label].
  final String? tooltip;

  /// Shape of the focus ring — match the visible control's corner radius.
  final BorderRadius borderRadius;

  /// Merge descendant semantics into this single button node (the default).
  /// Set to false when the child contains a *separate* control (e.g. a nested
  /// delete button) that must stay independently navigable.
  final bool mergeSemantics;

  final bool autofocus;

  @override
  State<AccessibleTap> createState() => _AccessibleTapState();
}

class _AccessibleTapState extends State<AccessibleTap> {
  bool _focused = false;

  bool get _enabled => widget.enabled && widget.onPressed != null;

  void _activate() {
    if (_enabled) widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final ringColor = Theme.of(context).colorScheme.primary;

    Widget content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _enabled ? _activate : null,
      child: Container(
        foregroundDecoration: _focused
            ? BoxDecoration(
                borderRadius: widget.borderRadius,
                border: Border.all(color: ringColor, width: 2),
              )
            : null,
        child: widget.child,
      ),
    );

    content = FocusableActionDetector(
      enabled: _enabled,
      autofocus: widget.autofocus,
      mouseCursor:
          _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      // Activate on Enter/Space regardless of app-level shortcut defaults.
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      // Only fires for keyboard/traversal focus, not pointer hover — exactly
      // the "focus visible" trigger we want.
      onShowFocusHighlight: (value) {
        if (value != _focused) setState(() => _focused = value);
      },
      child: content,
    );

    if (widget.tooltip != null) {
      content = Tooltip(message: widget.tooltip!, child: content);
    }

    content = Semantics(
      button: true,
      enabled: _enabled,
      selected: widget.selected,
      expanded: widget.expanded,
      label: widget.label,
      child: content,
    );

    return widget.mergeSemantics ? MergeSemantics(child: content) : content;
  }
}
