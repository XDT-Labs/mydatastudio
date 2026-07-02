import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/step_indicator_widget.dart';

void main() {
  group('StepIndicatorWidget', () {
    testWidgets('renders number and text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StepIndicatorWidget(number: 3, text: 'Do the thing'),
          ),
        ),
      );

      expect(find.text('3. '), findsOneWidget);
      expect(find.text('Do the thing'), findsOneWidget);
    });

    testWidgets('uses default color when none provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StepIndicatorWidget(number: 1, text: 'Step one'),
          ),
        ),
      );
      expect(find.byType(StepIndicatorWidget), findsOneWidget);
    });

    testWidgets('accepts custom color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StepIndicatorWidget(
              number: 2,
              text: 'Step two',
              color: Colors.red,
            ),
          ),
        ),
      );
      expect(find.text('2. '), findsOneWidget);
    });
  });
}
