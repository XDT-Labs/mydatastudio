import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_loading_view.dart';

void main() {
  group('GoogleDriveLoadingView', () {
    testWidgets('shows progress indicator', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GoogleDriveLoadingView()),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows connecting text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GoogleDriveLoadingView()),
        ),
      );

      expect(find.textContaining('Connecting'), findsOneWidget);
    });
  });
}
