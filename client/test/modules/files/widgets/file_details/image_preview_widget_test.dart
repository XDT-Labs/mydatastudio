import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/image_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/thumbnail_widget.dart';

import '../../../../helpers/file_fixture.dart';

void main() {
  group('ImagePreviewWidget', () {
    testWidgets('renders ThumbnailWidget when showOriginal is false and thumbnail is present', (tester) async {
      final file = makeTestFile(
        name: 'photo.jpg',
        contentType: 'image/jpeg',
        thumbnail: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImagePreviewWidget(
              file: file,
              resolvedPath: '/tmp/photo.jpg',
              showOriginal: false,
            ),
          ),
        ),
      );

      expect(find.byType(ThumbnailWidget), findsOneWidget);
    });

    testWidgets('falls back to ThumbnailWidget when showOriginal is true but original file does not exist', (tester) async {
      final file = makeTestFile(
        name: 'photo.jpg',
        contentType: 'image/jpeg',
        thumbnail: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImagePreviewWidget(
              file: file,
              resolvedPath: '/non-existent-path.jpg',
              showOriginal: true,
            ),
          ),
        ),
      );

      expect(find.byType(ThumbnailWidget), findsOneWidget);
    });
  });
}
