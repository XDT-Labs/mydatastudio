import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/widgets/scanning_placeholder_widget.dart';

void main() {
  group('ScanningPlaceholderWidget', () {
    testWidgets('shows progress indicator', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ScanningPlaceholderWidget()),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows collection name when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ScanningPlaceholderWidget(collectionName: 'My Inbox'),
          ),
        ),
      );

      expect(find.textContaining('My Inbox'), findsOneWidget);
    });

    testWidgets('shows fallback text when collection name is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ScanningPlaceholderWidget()),
        ),
      );

      expect(find.textContaining('emails'), findsOneWidget);
    });

    testWidgets('shows help text about large accounts', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ScanningPlaceholderWidget()),
        ),
      );

      expect(find.textContaining('minute'), findsOneWidget);
    });
  });
}
