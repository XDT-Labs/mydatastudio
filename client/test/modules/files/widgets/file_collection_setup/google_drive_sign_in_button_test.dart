import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_sign_in_button.dart';

void main() {
  group('GoogleDriveSignInButton', () {
    testWidgets('shows Sign in with Google text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveSignInButton(onTap: () {}),
          ),
        ),
      );

      expect(find.text('Sign in with Google'), findsOneWidget);
    });

    testWidgets('calls onTap when pressed', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveSignInButton(onTap: () => called = true),
          ),
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      expect(called, isTrue);
    });
  });
}
