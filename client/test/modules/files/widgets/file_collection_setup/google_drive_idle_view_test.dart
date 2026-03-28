import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_idle_view.dart';

void main() {
  group('GoogleDriveIdleView', () {
    testWidgets('shows Connect Google Drive heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(onConnect: () {}),
          ),
        ),
      );

      expect(find.text('Connect Google Drive'), findsOneWidget);
    });

    testWidgets('shows scope notice', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(onConnect: () {}),
          ),
        ),
      );

      expect(find.textContaining('Drive access'), findsOneWidget);
    });

    testWidgets('Cancel button is NOT present', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(onConnect: () {}),
          ),
        ),
      );

      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('sign in button calls onConnect', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () => called = true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();

      expect(called, isTrue);
    });
  });
}
