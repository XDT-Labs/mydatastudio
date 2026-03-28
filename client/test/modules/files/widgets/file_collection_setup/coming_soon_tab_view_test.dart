import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/coming_soon_tab_view.dart';

void main() {
  group('ComingSoonTabView', () {
    testWidgets('shows provider name in heading', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ComingSoonTabView(provider: 'Dropbox')),
        ),
      );

      expect(find.textContaining('Dropbox'), findsOneWidget);
      expect(find.textContaining('Coming Soon'), findsOneWidget);
    });

    testWidgets('shows working on it text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ComingSoonTabView(provider: 'OneDrive')),
        ),
      );

      expect(find.textContaining('working on'), findsOneWidget);
    });

    testWidgets('uses provider name from prop', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ComingSoonTabView(provider: 'Box')),
        ),
      );

      expect(find.textContaining('Box Coming Soon'), findsOneWidget);
    });
  });
}
