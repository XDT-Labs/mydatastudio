import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/widgets/email_detail/attachment_thumbnail_widget.dart';
import '../../../../helpers/file_fixture.dart';

void main() {
  group('AttachmentThumbnailWidget', () {
    testWidgets('shows file name', (tester) async {
      final file = makeTestFile(
        name: 'report.pdf',
        path: '/nonexistent/report.pdf',
        contentType: 'application/pdf',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentThumbnailWidget(file: file),
          ),
        ),
      );

      expect(find.text('report.pdf'), findsOneWidget);
    });

    testWidgets('shows pdf icon for pdf content type', (tester) async {
      final file = makeTestFile(
        name: 'doc.pdf',
        path: '/nonexistent/doc.pdf',
        contentType: 'application/pdf',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentThumbnailWidget(file: file),
          ),
        ),
      );

      expect(find.byIcon(Icons.picture_as_pdf), findsOneWidget);
    });

    testWidgets('shows video icon for video content type', (tester) async {
      final file = makeTestFile(
        name: 'clip.mp4',
        path: '/nonexistent/clip.mp4',
        contentType: 'video/mp4',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentThumbnailWidget(file: file),
          ),
        ),
      );

      expect(find.byIcon(Icons.video_file), findsOneWidget);
    });

    testWidgets('shows generic icon for unknown content type', (tester) async {
      final file = makeTestFile(
        name: 'data.bin',
        path: '/nonexistent/data.bin',
        contentType: 'application/octet-stream',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentThumbnailWidget(file: file),
          ),
        ),
      );

      expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
    });
  });
}
