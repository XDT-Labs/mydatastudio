import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/thumbnail_widget.dart';

void main() {
  group('ThumbnailWidget', () {
    testWidgets('renders MemoryImage for base64 thumbnail', (tester) async {
      // 1x1 transparent PNG base64
      const thumbnail =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ThumbnailWidget(thumbnail: thumbnail)),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('renders network Image for http thumbnail', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ThumbnailWidget(thumbnail: 'https://example.com/thumb.jpg'),
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<NetworkImage>());
    });
  });
}
