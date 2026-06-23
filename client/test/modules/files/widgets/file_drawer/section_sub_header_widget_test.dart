import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_drawer/section_sub_header_widget.dart';

void main() {
  group('SectionSubHeaderWidget', () {
    testWidgets('shows title in uppercase', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SectionSubHeaderWidget(title: 'Local Sources')),
        ),
      );

      expect(find.text('LOCAL SOURCES'), findsOneWidget);
    });

    testWidgets('renders with any title string', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SectionSubHeaderWidget(title: 'Google Drive')),
        ),
      );

      expect(find.text('GOOGLE DRIVE'), findsOneWidget);
    });
  });
}
