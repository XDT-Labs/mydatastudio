import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_detail/attachment_thumbnail_widget.dart';
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
          home: Scaffold(body: AttachmentThumbnailWidget(file: file)),
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
          home: Scaffold(body: AttachmentThumbnailWidget(file: file)),
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
          home: Scaffold(body: AttachmentThumbnailWidget(file: file)),
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
          home: Scaffold(body: AttachmentThumbnailWidget(file: file)),
        ),
      );

      expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
    });

    testWidgets('offers open and save actions', (tester) async {
      // Tapping the tile opens the file, but that is invisible — an attachment
      // needs controls the user can see, and saving a copy out of the app's
      // data directory has no other route at all.
      final file = makeTestFile(
        name: 'doc.pdf',
        path: '/nonexistent/doc.pdf',
        contentType: 'application/pdf',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AttachmentThumbnailWidget(file: file)),
        ),
      );

      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      expect(find.byIcon(Icons.download), findsOneWidget);
    });

    group('image previews', () {
      // The scanners disagree about what they write to content_type: PST,
      // Yahoo and Outlook store the app's own category, only Gmail stores a
      // real MIME type. Checking for 'image/' alone meant no PST attachment
      // ever previewed — it fell through to the generic file icon.
      for (final contentType in const ['application/image', 'image/jpeg']) {
        testWidgets('renders an image for $contentType', (tester) async {
          final file = makeTestFile(
            name: 'photo.jpg',
            path: '/nonexistent/photo.jpg',
            contentType: contentType,
          );

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: AttachmentThumbnailWidget(file: file)),
            ),
          );

          expect(find.byType(Image), findsOneWidget);
          expect(find.byIcon(Icons.insert_drive_file), findsNothing);
        });
      }
    });
  });
}
