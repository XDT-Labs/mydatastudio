import 'package:mydatatools/app_router.dart';
import 'package:mydatatools/color_schemes.g.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class FamilyDamApp extends StatelessWidget {
  const FamilyDamApp({super.key});

  ThemeData _buildTheme(ColorScheme colorScheme, BuildContext context) {
    final baseTextTheme = GoogleFonts.interTextTheme(Theme.of(context).textTheme);
    
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
      textTheme: baseTextTheme.copyWith(
        displayLarge: GoogleFonts.manrope(fontSize: 57, fontWeight: FontWeight.normal),
        displayMedium: GoogleFonts.manrope(fontSize: 45, fontWeight: FontWeight.normal),
        displaySmall: GoogleFonts.manrope(fontSize: 36, fontWeight: FontWeight.normal),
        headlineLarge: GoogleFonts.manrope(fontSize: 32, fontWeight: FontWeight.normal),
        headlineMedium: GoogleFonts.manrope(fontSize: 28, fontWeight: FontWeight.normal),
        headlineSmall: GoogleFonts.manrope(fontSize: 24, fontWeight: FontWeight.normal),
        titleLarge: GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w400),
        titleMedium: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w400),
        titleSmall: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w400),
        bodyLarge: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w400),
        bodyMedium: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w400),
        bodySmall: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400),
        labelLarge: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
        labelMedium: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500),
        labelSmall: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.5),
      ).apply(
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
      ),
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
        selectedLabelTextStyle: GoogleFonts.inter(color: colorScheme.primary),
        unselectedLabelTextStyle: GoogleFonts.inter(color: colorScheme.onSurfaceVariant),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        elevation: 0,
      ),
      dataTableTheme: DataTableThemeData(
        dividerThickness: 0, // "The No-Line Rule"
        dataRowColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) {
            return colorScheme.surfaceContainerHigh;
          }
          return Colors.transparent;
        }),
        headingTextStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurfaceVariant,
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
      title: "MyData / Tools",
      debugShowCheckedModeBanner: false,
      routerConfig: AppRouter.instance,
      theme: _buildTheme(lightColorScheme, context),
      darkTheme: _buildTheme(darkColorScheme, context),
      themeMode: ThemeMode.system,
    );
  }
}
