import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/modules/files/widgets/file_drawer.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import '../../../helpers/file_fixture.dart';

void main() {
  setUp(() {
    GetCollectionsService.instance.reset();
  });

  testWidgets('FileDrawer renders Local Drive and Google Drive headers without Cloud Drives wrapper', (tester) async {
    final localCol = makeTestCollection(
      name: 'My Computer',
      type: 'file',
      scanner: AppConstants.scannerFileLocal,
    );
    final gdriveCol = makeTestCollection(
      name: 'Drive (user@example.com)',
      type: 'file',
      scanner: AppConstants.scannerFileGDrive,
    );

    GetCollectionsService.instance.sink.add([localCol, gdriveCol]);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FileDrawer(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify SOURCES header exists
    expect(find.text('SOURCES'), findsOneWidget);

    // Verify "Cloud Drives" header is NOT rendered
    expect(find.text('Cloud Drives'), findsNothing);

    // Verify "Local Drive" and "Google Drive" accordion headers exist directly
    expect(find.text('Local Drive'), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);
  });
}
