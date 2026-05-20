import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_idle_view.dart';

void main() {
  group('GoogleDriveIdleView', () {
    testWidgets('shows Connect Google Drive heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () {},
              saveLocalCopy: true,
              onSaveLocalCopyChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Connect Google Drive'), findsOneWidget);
    });

    testWidgets('shows scope notice', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () {},
              saveLocalCopy: true,
              onSaveLocalCopyChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.textContaining('Drive access'), findsOneWidget);
    });

    testWidgets('Cancel button is NOT present', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () {},
              saveLocalCopy: true,
              onSaveLocalCopyChanged: (_) {},
            ),
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
              saveLocalCopy: true,
              onSaveLocalCopyChanged: (_) {},
            ),
          ),
        ),
      );

      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();

      expect(called, isTrue);
    });

    testWidgets('checkbox toggles local copy preference', (tester) async {
      bool? lastValue;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () {},
              saveLocalCopy: true,
              onSaveLocalCopyChanged: (val) => lastValue = val,
            ),
          ),
        ),
      );

      final checkbox = find.byType(Checkbox);
      expect(checkbox, findsOneWidget);

      await tester.tap(find.textContaining('Save a local copy'));
      await tester.pump();

      expect(lastValue, isFalse);
    });
  });
}
