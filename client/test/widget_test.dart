import 'package:flutter/material.dart';
import 'package:mydatatools/family_dam_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App starts and shows SetupPage', (WidgetTester tester) async {
    // Set a larger screen size to avoid Stepper overflow
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;

    // Build our app and trigger a frame.
    await tester.pumpWidget(const FamilyDamApp());

    // Verify that the app shows the SetupPage (since DatabaseManager is not initialized in tests)
    // We expect to find 'MyData Tools' text.
    // Use pumpAndSettle to handle any redirects or animations
    await tester.pumpAndSettle();
    
    expect(find.text('MyData Tools'), findsOneWidget);

    // Reset the size after the test
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
