import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/widgets/accessible_tap.dart';

/// The size floor exists so a call site cannot ship a tap target below the
/// WCAG 2.2 AA 2.5.8 minimum by simply forgetting to size its child. It must
/// only ever *raise* an undersized target — silently resizing controls that are
/// already large enough would change existing layouts.
void main() {
  Future<Size> pumpTap(
    WidgetTester tester, {
    required Widget child,
    double? minSize,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: AccessibleTap(
              label: 'target',
              onPressed: () {},
              minSize: minSize ?? 24,
              child: child,
            ),
          ),
        ),
      ),
    );
    return tester.getSize(find.byType(AccessibleTap));
  }

  testWidgets('raises an undersized child to the 24x24 AA minimum', (
    tester,
  ) async {
    final size = await pumpTap(
      tester,
      child: const Icon(Icons.close, size: 14),
    );
    expect(size, const Size(24, 24));
  });

  testWidgets('leaves a child that already exceeds the minimum untouched', (
    tester,
  ) async {
    final size = await pumpTap(
      tester,
      child: const SizedBox(width: 120, height: 38),
    );
    expect(size, const Size(120, 38));
  });

  testWidgets('honours a larger minSize for AAA-sized targets', (tester) async {
    final size = await pumpTap(
      tester,
      child: const Icon(Icons.close, size: 14),
      minSize: 44,
    );
    expect(size, const Size(44, 44));
  });
}
