import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_details/folder_metadata_section.dart';

void main() {
  group('FolderMetadataSection', () {
    testWidgets('renders folder name and path', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FolderMetadataSection(
              name: 'Documents',
              path: '/Users/test/Documents',
            ),
          ),
        ),
      );
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('/Users/test/Documents'), findsOneWidget);
      expect(find.text('FOLDER INFO'), findsOneWidget);
    });
  });
}
