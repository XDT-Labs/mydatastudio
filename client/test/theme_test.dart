import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/family_dam_app.dart';

void main() {
  testWidgets('App starts in dark mode and uses darkColorScheme', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(const FamilyDamApp());
    await tester.pumpAndSettle();

    // Verify that we can resolve ThemeData from the app structure
    final BuildContext context = tester.element(find.byType(Navigator).first);
    final theme = Theme.of(context);

    // Verify darkColorScheme is active
    expect(theme.colorScheme.brightness, equals(Brightness.dark));
    expect(theme.colorScheme.primary, equals(const Color(0xFFE8DDFF)));
    expect(theme.colorScheme.surface, equals(const Color(0xFF141317)));
    expect(theme.colorScheme.onSurface, equals(const Color(0xFFE6E1E8)));

    // Reset the size after the test
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
