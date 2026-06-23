import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_success_view.dart';

void main() {
  group('GoogleDriveSuccessView', () {
    testWidgets('shows connected heading', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GoogleDriveSuccessView(connectedEmail: null)),
        ),
      );

      expect(find.textContaining('Connected'), findsOneWidget);
    });

    testWidgets('shows email when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GoogleDriveSuccessView(connectedEmail: 'user@example.com'),
          ),
        ),
      );

      expect(find.text('user@example.com'), findsOneWidget);
    });

    testWidgets('hides email when null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GoogleDriveSuccessView(connectedEmail: null)),
        ),
      );

      expect(find.text('user@example.com'), findsNothing);
    });

    testWidgets('shows scanning message', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GoogleDriveSuccessView(connectedEmail: null)),
        ),
      );

      expect(find.textContaining('canning'), findsOneWidget);
    });
  });
}
