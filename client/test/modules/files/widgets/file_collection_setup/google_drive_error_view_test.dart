import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_error_view.dart';

void main() {
  group('GoogleDriveErrorView', () {
    testWidgets('shows Connection Failed heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveErrorView(
              errorMessage: null,
              onRetry: () {},
            ),
          ),
        ),
      );

      expect(find.text('Connection Failed'), findsOneWidget);
    });

    testWidgets('shows error message when provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveErrorView(
              errorMessage: 'Auth timeout',
              onRetry: () {},
            ),
          ),
        ),
      );

      expect(find.text('Auth timeout'), findsOneWidget);
    });

    testWidgets('hides error message when null', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveErrorView(
              errorMessage: null,
              onRetry: () {},
            ),
          ),
        ),
      );

      expect(find.text('Auth timeout'), findsNothing);
    });

    testWidgets('retry button calls onRetry', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveErrorView(
              errorMessage: null,
              onRetry: () => called = true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Try Again'));
      await tester.pump();

      expect(called, isTrue);
    });

    testWidgets('Cancel button is NOT present', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveErrorView(
              errorMessage: null,
              onRetry: () {},
            ),
          ),
        ),
      );

      expect(find.text('Cancel'), findsNothing);
    });
  });
}
