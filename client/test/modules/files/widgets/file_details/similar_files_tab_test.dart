import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/similar_files_tab.dart';

void main() {
  group('SimilarFilesTab', () {
    testWidgets('renders coming soon placeholder', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SimilarFilesTab())),
      );
      expect(find.text('Coming Soon'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    });
  });
}
