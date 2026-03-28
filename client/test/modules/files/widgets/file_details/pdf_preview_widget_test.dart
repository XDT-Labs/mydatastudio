import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_details/pdf_preview_widget.dart';

void main() {
  group('PdfPreviewWidget', () {
    testWidgets('shows loading indicator on first pump (no testController)',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PdfPreviewWidget(
              filePath: '/tmp/nonexistent.pdf',
              previewHeight: 300,
            ),
          ),
        ),
      );
      // initState async hasn't resolved — loading state visible immediately.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    // Error state requires PdfDocument.openFile to resolve in the test runner,
    // which blocks on platform channels not available headless. Covered manually.
  });
}
