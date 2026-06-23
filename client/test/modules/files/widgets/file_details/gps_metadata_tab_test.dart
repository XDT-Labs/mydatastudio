import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/gps_metadata_tab.dart';

import '../../../../helpers/fake_tile_provider.dart';
import '../../../../helpers/file_fixture.dart';

void main() {
  group('GpsMetadataTab', () {
    testWidgets(
      'shows no-data state when exifData is null and file has no coords',
      (tester) async {
        final file = makeTestFile();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: GpsMetadataTab(exifData: null, file: file)),
          ),
        );
        expect(find.text('No GPS data found.'), findsOneWidget);
      },
    );

    testWidgets('shows no-data when file has no coords and exifData empty', (
      tester,
    ) async {
      final file = makeTestFile();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GpsMetadataTab(exifData: {}, file: file)),
        ),
      );
      expect(find.text('No GPS data found.'), findsOneWidget);
    });

    testWidgets('renders lat/lng rows when file has coordinates', (
      tester,
    ) async {
      final file = makeTestFile(latitude: 37.7749, longitude: -122.4194);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 400,
              child: GpsMetadataTab(
                exifData: null,
                file: file,
                tileProvider: FakeMemoryTileProvider(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Latitude'), findsOneWidget);
      expect(find.text('Longitude'), findsOneWidget);
    });
  });
}
