import 'package:flutter/material.dart';

const lightColorScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF3452D4),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFF607BFE),
  onPrimaryContainer: Color(0xFFFFFFFF),
  secondary: Color(0xFF596064),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFDFE1F9),
  onSecondaryContainer: Color(0xFF3452D4),
  tertiary: Color(0xFF7D5260),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFFFD8E4),
  onTertiaryContainer: Color(0xFF31111D),
  error: Color(0xFFB3261E),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF410E0B),
  outline: Color(0xFF596064),
  outlineVariant: Color(0x33596064), // 20% opacity ghost border

  surface: Color(0xFFF8F9FB),
  onSurface: Color(0xFF2C3437),

  onSurfaceVariant: Color(0xFF596064),
  inverseSurface: Color(0xFF2C3437),
  onInverseSurface: Color(0xFFF8F9FB),
  inversePrimary: Color(0xFF607BFE),
  shadow: Color(0x0A2C3437), // 4% opacity of onSurface for ambient shadow
  surfaceTint: Color(0xFF3452D4),
  scrim: Color(0xFF000000),
  
  // Custom Material 3 container colors mapped to the Digital Curator specifications
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF0F4F6),
  surfaceContainer: Color(0xFFEAEFF2),
  surfaceContainerHigh: Color(0xFFE3E8EB),
  surfaceContainerHighest: Color(0xFFDCE1E4),
);


const darkColorScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFE8DDFF),
  onPrimary: Color(0xFF36265E),
  primaryContainer: Color(0xFFCFBCFF),
  onPrimaryContainer: Color(0xFF594983),
  secondary: Color(0xFFCCC2DC),
  onSecondary: Color(0xFF332D41),
  secondaryContainer: Color(0xFF4A4359),
  onSecondaryContainer: Color(0xFFBAB1CA),
  tertiary: Color(0xFFFFDF97),
  onTertiary: Color(0xFF3F2E00),
  tertiaryContainer: Color(0xFFEFC048),
  onTertiaryContainer: Color(0xFF684E00),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
  errorContainer: Color(0xFF93000A),
  onErrorContainer: Color(0xFFFFDAD6),
  outline: Color(0xFF948F9A),
  outlineVariant: Color(0xFF49454F),

  surface: Color(0xFF141317),
  onSurface: Color(0xFFE6E1E8),

  surfaceVariant: Color(0xFF363439),
  onSurfaceVariant: Color(0xFFCAC4D0),
  inverseSurface: Color(0xFFE6E1E8),
  onInverseSurface: Color(0xFF322F35),
  inversePrimary: Color(0xFF655590),
  shadow: Color(0x0A000000),
  surfaceTint: Color(0xFFCFBCFF),
  scrim: Color(0xFF000000),
  
  // Custom Material 3 container colors mapped to the Digital Curator specifications
  surfaceContainerLowest: Color(0xFF0F0D12),
  surfaceContainerLow: Color(0xFF1D1B20),
  surfaceContainer: Color(0xFF211F24),
  surfaceContainerHigh: Color(0xFF2B292E),
  surfaceContainerHighest: Color(0xFF363439),
);



