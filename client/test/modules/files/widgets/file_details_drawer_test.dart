import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_details_drawer.dart';
import 'package:mydatatools/modules/files/widgets/file_details/file_metadata_section.dart';

import '../../../helpers/file_fixture.dart';

void main() {
  group('FileDetailsDrawer', () {
    testWidgets('renders file metadata and invokes callbacks', (tester) async {
      final file = makeTestFile(
        name: 'sample_photo.jpg',
        path: '/tmp/sample_photo.jpg',
        contentType: 'image/jpeg',
        size: 512000,
      );
      final collection = makeTestCollection(name: 'My Photos');

      bool closeCalled = false;
      bool expandCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileDetailsDrawer(
              asset: file,
              collection: collection,
              width: 300.0,
              onClose: () {
                closeCalled = true;
              },
              onExpand: () {
                expandCalled = true;
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify file metadata section is rendered with correct name
      expect(find.text('sample_photo.jpg'), findsOneWidget);
      expect(find.byType(FileMetadataSection), findsOneWidget);

      // Verify the close button is interactive
      final closeButtonFinder = find.byTooltip('Close');
      expect(closeButtonFinder, findsOneWidget);
      await tester.tap(closeButtonFinder);
      expect(closeCalled, isTrue);

      // Verify the expand/collapse button is interactive
      final expandButtonFinder = find.byTooltip('Maximize Width');
      expect(expandButtonFinder, findsOneWidget);
      await tester.tap(expandButtonFinder);
      expect(expandCalled, isTrue);
    });
  });
}
