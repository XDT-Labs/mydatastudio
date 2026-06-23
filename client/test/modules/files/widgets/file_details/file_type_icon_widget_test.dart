import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/file_type_icon_widget.dart';

void main() {
  group('FileTypeIconWidget', () {
    testWidgets('renders pdf icon when isPdf=true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FileTypeIconWidget(
              contentType: 'application/pdf',
              isPdf: true,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.picture_as_pdf), findsOneWidget);
    });

    testWidgets('renders video icon for video contentType', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: FileTypeIconWidget(contentType: 'video/mp4')),
        ),
      );
      expect(find.byIcon(Icons.video_file), findsOneWidget);
    });

    testWidgets('renders audio icon for audio contentType', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: FileTypeIconWidget(contentType: 'audio/mpeg')),
        ),
      );
      expect(find.byIcon(Icons.audio_file), findsOneWidget);
    });

    testWidgets('renders text icon for text contentType', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: FileTypeIconWidget(contentType: 'text/plain')),
        ),
      );
      expect(find.byIcon(Icons.text_snippet), findsOneWidget);
    });

    testWidgets('renders STL icon for .stl fileName', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FileTypeIconWidget(
              contentType: 'application/octet-stream',
              fileName: 'model.stl',
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.view_in_ar), findsOneWidget);
    });

    testWidgets('renders generic file icon by default', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FileTypeIconWidget(contentType: 'application/zip'),
          ),
        ),
      );
      expect(find.byIcon(Icons.file_present), findsOneWidget);
    });
  });
}
