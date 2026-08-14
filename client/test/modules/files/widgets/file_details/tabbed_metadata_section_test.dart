import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/exif_metadata_tab.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/gps_metadata_tab.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/tabbed_metadata_section.dart';

import '../../../../helpers/fake_tile_provider.dart';
import '../../../../helpers/file_fixture.dart';

void main() {
  group('TabbedMetadataSection', () {
    testWidgets(
      'renders EXIF tab first by default and loads Location tab when tapped',
      (tester) async {
        final file = makeTestFile(latitude: 37.7749, longitude: -122.4194);
        final collection = makeTestCollection();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DefaultTabController(
                length: 3,
                child: SizedBox(
                  height: 500,
                  child: TabbedMetadataSection(
                    file: file,
                    collection: collection,
                    exifData: null,
                    isLoadingExif: false,
                    showExif: true,
                    tileProvider: FakeMemoryTileProvider(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Verify EXIF tab is active by default and ExifMetadataTab is visible
        expect(find.byType(ExifMetadataTab), findsOneWidget);
        expect(find.text('No EXIF data available.'), findsOneWidget);

        // 2. Verify Location tab content (GpsMetadataTab) is NOT in the tree initially
        expect(find.byType(GpsMetadataTab), findsNothing);

        // 3. Tap the Location tab
        await tester.tap(find.text('LOCATION'));
        await tester.pumpAndSettle();

        // 4. Verify GpsMetadataTab is now rendered
        expect(find.byType(GpsMetadataTab), findsOneWidget);
        expect(find.text('Latitude'), findsOneWidget);
        expect(find.text('Longitude'), findsOneWidget);
      },
    );
  });
}
