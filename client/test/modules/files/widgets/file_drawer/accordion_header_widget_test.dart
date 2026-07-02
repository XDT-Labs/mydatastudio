import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_drawer/accordion_header_widget.dart';

void main() {
  group('AccordionHeaderWidget', () {
    testWidgets('shows title', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccordionHeaderWidget(
              title: 'Files',
              icon: Icons.folder,
              isExpanded: false,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('Files'), findsOneWidget);
    });

    testWidgets('shows right arrow when collapsed', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccordionHeaderWidget(
              title: 'Files',
              icon: Icons.folder,
              isExpanded: false,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.keyboard_arrow_right), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
    });

    testWidgets('shows down arrow when expanded', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccordionHeaderWidget(
              title: 'Files',
              icon: Icons.folder,
              isExpanded: true,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_right), findsNothing);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccordionHeaderWidget(
              title: 'Files',
              icon: Icons.folder,
              isExpanded: false,
              onTap: () => called = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(GestureDetector));
      await tester.pump();

      expect(called, isTrue);
    });
  });
}
