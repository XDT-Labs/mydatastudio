import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_details/section_widget.dart';

void main() {
  group('SectionWidget', () {
    testWidgets('renders title and children', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionWidget(
              title: 'File Info',
              icon: Icons.description_outlined,
              children: [Text('child row')],
            ),
          ),
        ),
      );
      expect(find.text('FILE INFO'), findsOneWidget);
      expect(find.text('child row'), findsOneWidget);
    });

    testWidgets('renders icon', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionWidget(
              title: 'Test',
              icon: Icons.folder_outlined,
              children: [],
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    });
  });
}
