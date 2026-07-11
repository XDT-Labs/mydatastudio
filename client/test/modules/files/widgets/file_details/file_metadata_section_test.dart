import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/file_metadata_section.dart';

import '../../../../helpers/file_fixture.dart';

void main() {
  group('FileMetadataSection', () {
    testWidgets('renders file name, type, and path', (tester) async {
      final file = makeTestFile(
        name: 'photo.jpg',
        path: '/tmp/photo.jpg',
        contentType: 'image/jpeg',
        size: 2048,
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FileMetadataSection(file: file))),
      );
      await tester.pumpAndSettle();
      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('image/jpeg'), findsOneWidget);
      expect(find.text('/tmp/photo.jpg'), findsOneWidget);
      expect(find.text('FILE INFO'), findsOneWidget);
    });

    testWidgets('shows download URL row when present', (tester) async {
      final file = makeTestFile(
        name: 'file.pdf',
        downloadUrl: 'https://example.com/file.pdf',
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: FileMetadataSection(file: file))),
      );
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/file.pdf'), findsOneWidget);
    });

    testWidgets('renders resolution when provided', (tester) async {
      final file = makeTestFile(
        name: 'photo.jpg',
        path: '/tmp/photo.jpg',
        contentType: 'image/jpeg',
        size: 2048,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileMetadataSection(
              file: file,
              resolution: '1024x768',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Resolution'), findsOneWidget);
      expect(find.text('1024x768'), findsOneWidget);
    });
  });
}
