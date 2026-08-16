import 'package:mydatastudio/app_router.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:material_ui/material_ui.dart';

class FamilyDamApp extends StatelessWidget {
  const FamilyDamApp({super.key});

  static const String _fontFamily = '.AppleSystemUIFont';
  static const List<String> _fontFamilyFallback = [
    'Inter',
    'Segoe UI',
    'sans-serif',
  ];

  ThemeData _buildTheme(ColorScheme colorScheme, BuildContext context) {
    final textTheme = ThemeData.light().textTheme
        .copyWith(
          displayLarge: const TextStyle(
            fontSize: 56,
            fontWeight: FontWeight.normal,
            letterSpacing: -0.5,
          ),
          displayMedium: const TextStyle(
            fontSize: 44,
            fontWeight: FontWeight.normal,
            letterSpacing: -0.5,
          ),
          displaySmall: const TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.normal,
            letterSpacing: -0.25,
          ),
          headlineLarge: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.2,
          ),
          headlineMedium: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.2,
          ),
          headlineSmall: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.15,
          ),
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.15,
          ),
          titleMedium: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.1,
          ),
          titleSmall: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.1,
          ),
          bodyLarge: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            height: 1.4,
            letterSpacing: -0.1,
          ),
          bodyMedium: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w400,
            height: 1.4,
            letterSpacing: -0.1,
          ),
          bodySmall: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            height: 1.35,
            letterSpacing: 0.0,
          ),
          labelLarge: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.1,
          ),
          labelMedium: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.0,
          ),
          labelSmall: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        )
        .apply(
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFamilyFallback,
          bodyColor: colorScheme.onSurface,
          displayColor: colorScheme.onSurface,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      dividerColor: Colors.transparent, // "The No-Line Rule"
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      textTheme: textTheme,
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.surfaceContainerLowest,
        foregroundColor: colorScheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 2,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        indicatorColor: colorScheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        selectedIconTheme: IconThemeData(color: colorScheme.primary),
        unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: colorScheme.primary,
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFamilyFallback,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFamilyFallback,
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        elevation: 0,
      ),
      dataTableTheme: DataTableThemeData(
        dividerThickness: 0, // "The No-Line Rule"
        dataRowColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected) ||
              states.contains(WidgetState.pressed)) {
            return colorScheme.primaryContainer.withValues(alpha: 0.2);
          }
          if (states.contains(WidgetState.hovered)) {
            return colorScheme.surfaceContainerHigh;
          }
          return Colors.transparent;
        }),
        headingTextStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurfaceVariant,
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFamilyFallback,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return null;
        }),
        checkColor: WidgetStateProperty.all(colorScheme.onPrimary),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        shadowColor: colorScheme.shadow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8.0),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      restorationScopeId: 'mydata.tools',
      title: "My Data Studio",
      debugShowCheckedModeBanner: false,
      routerConfig: AppRouter.instance,
      theme: _buildTheme(lightColorScheme, context),
      darkTheme: _buildTheme(darkColorScheme, context),
      themeMode: ThemeMode.dark,
    );
  }
}
