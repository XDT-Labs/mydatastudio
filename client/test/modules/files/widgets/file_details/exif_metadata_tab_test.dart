import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/exif_metadata_tab.dart';

void main() {
  group('ExifMetadataTab', () {
    testWidgets('shows loading indicator when isLoading=true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ExifMetadataTab(exifData: null, isLoading: true),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows no-data message when exifData is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ExifMetadataTab(exifData: null, isLoading: false),
          ),
        ),
      );
      expect(find.text('No EXIF data available.'), findsOneWidget);
    });

    testWidgets('shows no-data message when exifData is empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ExifMetadataTab(exifData: {}, isLoading: false)),
        ),
      );
      expect(find.text('No EXIF data available.'), findsOneWidget);
    });
  });
}
