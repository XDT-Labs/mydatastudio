import 'package:material_ui/material_ui.dart';
import 'package:flutter/material.dart' as m;

/// Restates a [ThemeData] as the in-SDK Material [m.ThemeData] that
/// `MarkdownStyleSheet.fromTheme` still demands.
///
/// The two are unrelated classes with the same name: the app moved to
/// `package:material_ui`, flutter_markdown_plus has not, and there is no
/// conversion between them because `ThemeData`, `TextTheme` and `CardThemeData`
/// each exist twice over. Only [TextStyle] and [Color] are shared, which is
/// what makes this bridge possible at all.
///
/// Only the five text styles and three colours `fromTheme` actually reads are
/// carried across — see its source, everything else it sets is a constant. Each
/// style is merged *onto* the SDK's own default rather than replacing it, so a
/// field the app theme leaves null (notably `bodyMedium.fontSize`, which
/// `fromTheme` asserts on) still arrives populated.
m.ThemeData markdownThemeOf(ThemeData theme) {
  final base = m.ThemeData(brightness: theme.brightness);
  final defaults = base.textTheme;
  final source = theme.textTheme;

  return base.copyWith(
    textTheme: m.TextTheme(
      bodyMedium: defaults.bodyMedium?.merge(source.bodyMedium),
      bodyLarge: defaults.bodyLarge?.merge(source.bodyLarge),
      headlineSmall: defaults.headlineSmall?.merge(source.headlineSmall),
      titleLarge: defaults.titleLarge?.merge(source.titleLarge),
      titleMedium: defaults.titleMedium?.merge(source.titleMedium),
    ),
    cardTheme: m.CardThemeData(color: theme.cardTheme.color),
    primaryColor: theme.primaryColor,
    dividerColor: theme.dividerColor,
  );
}
