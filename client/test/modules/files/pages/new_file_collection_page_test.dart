import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/file_sources/sync_folder/sync_folder_detector.dart';
import 'package:mydatastudio/modules/files/pages/new_file_collection_page.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/file_source_catalog.dart';

class _FakeDetector extends SyncFolderDetector {
  _FakeDetector(this.results);
  final List<DetectedSyncFolder> results;

  @override
  List<DetectedSyncFolder> detect() => results;
}

const _icloud = DetectedSyncFolder(
  provider: SyncProvider.iCloudDrive,
  displayName: 'iCloud Drive',
  path: '/Users/me/Library/Mobile Documents/com~apple~CloudDocs',
);
const _dropboxFolder = DetectedSyncFolder(
  provider: SyncProvider.dropbox,
  displayName: 'Dropbox folder',
  path: '/Users/me/Library/CloudStorage/Dropbox',
);

Finder _tile(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(FileSourceTile));

final _macHeader = find.byKey(const ValueKey('group-thisMac'));

void main() {
  Future<void> pump(
    WidgetTester tester, {
    List<DetectedSyncFolder> found = const [],
    Set<String> existing = const {},
    ExistingCollectionPaths? existingPaths,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/files/add',
      routes: [
        GoRoute(
          path: '/files/add',
          builder:
              (context, state) => Scaffold(
                body: NewFileCollectionPage(
                  detector: _FakeDetector(found),
                  existingPaths: existingPaths ?? () async => existing,
                ),
              ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.pump();
  }

  group('catalog', () {
    testWidgets('groups sources into this Mac and cloud accounts', (
      tester,
    ) async {
      await pump(tester);
      expect(_macHeader, findsOneWidget);
      expect(find.byKey(const ValueKey('group-cloudAccounts')), findsOneWidget);
      for (final title in [
        'Any folder',
        'Network drive',
        'External drive',
        'Google Drive',
        'Dropbox',
        'OneDrive',
        'Box',
      ]) {
        expect(_tile(title), findsOneWidget, reason: title);
      }
    });

    testWidgets('detected sync folders appear as Found tiles', (tester) async {
      await pump(tester, found: [_icloud, _dropboxFolder]);
      expect(_tile('iCloud Drive'), findsOneWidget);
      expect(_tile('Dropbox folder'), findsOneWidget);
      expect(find.text('Found'), findsNWidgets(2));
    });

    testWidgets('a folder that is already a collection is shown disabled', (
      tester,
    ) async {
      // Adding the same sync folder twice would scan it twice; keeping the
      // tile tells the user it was found and is already covered.
      await pump(
        tester,
        found: [_icloud, _dropboxFolder],
        existing: {_icloud.path},
      );
      expect(_tile('iCloud Drive'), findsOneWidget);
      expect(find.text('Added'), findsOneWidget);
      expect(find.text('Found'), findsOneWidget);

      await tester.tap(_tile('iCloud Drive'));
      await tester.pump();
      expect(find.text('All sources'), findsNothing);
    });

    testWidgets('disables folders nested under an existing collection', (
      tester,
    ) async {
      const nested = DetectedSyncFolder(
        provider: SyncProvider.googleDrive,
        displayName: 'Google Drive - My Drive',
        path: '/Users/me/Library/CloudStorage/GoogleDrive-a@x.com/My Drive',
      );
      await pump(
        tester,
        found: [nested, _dropboxFolder],
        existing: {'/Users/me/Library/CloudStorage/GoogleDrive-a@x.com/'},
      );
      expect(_tile('Google Drive - My Drive'), findsOneWidget);
      expect(find.text('Added'), findsOneWidget);
      expect(_tile('Dropbox folder'), findsOneWidget);
    });

    testWidgets('a failed lookup still leaves the manual sources usable', (
      tester,
    ) async {
      await pump(
        tester,
        found: [_icloud],
        existingPaths: () async => throw Exception('db down'),
      );
      expect(_tile('iCloud Drive'), findsNothing);
      expect(_tile('Any folder'), findsOneWidget);
    });

    testWidgets('search narrows the tiles by title', (tester) async {
      await pump(tester, found: [_icloud]);
      await tester.enterText(find.byType(TextField), 'drop');
      await tester.pump();
      expect(_tile('Dropbox'), findsOneWidget);
      expect(_tile('iCloud Drive'), findsNothing);
      expect(_tile('Any folder'), findsNothing);
      expect(_macHeader, findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
    });
  });

  group('source forms', () {
    testWidgets('coming-soon sources are marked and do not open a form', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Soon'), findsNWidgets(3));
      await tester.tap(_tile('Dropbox'));
      await tester.pump();
      expect(find.text('All sources'), findsNothing);
      expect(_macHeader, findsOneWidget);
    });

    testWidgets('Any folder opens the folder form; back returns', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(_tile('Any folder'));
      await tester.pump();
      expect(find.text('Folder *'), findsOneWidget);
      expect(_macHeader, findsNothing);

      await tester.tap(find.text('All sources'));
      await tester.pump();
      expect(_macHeader, findsOneWidget);
    });

    testWidgets('Cancel in a form returns to the catalog', (tester) async {
      await pump(tester);
      await tester.tap(_tile('Network drive'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(_macHeader, findsOneWidget);
    });

    testWidgets('a found folder opens its form prefilled', (tester) async {
      await pump(tester, found: [_icloud]);
      await tester.tap(_tile('iCloud Drive'));
      await tester.pump();
      final fields = tester.widgetList<TextFormField>(
        find.byType(TextFormField),
      );
      expect(fields.map((f) => f.controller!.text), [
        'iCloud Drive',
        _icloud.path,
      ]);
    });

    testWidgets('a new form does not keep the previous source values', (
      tester,
    ) async {
      await pump(tester, found: [_icloud]);
      await tester.tap(_tile('iCloud Drive'));
      await tester.pump();
      await tester.tap(find.text('All sources'));
      await tester.pump();
      await tester.tap(_tile('Any folder'));
      await tester.pump();
      final fields = tester.widgetList<TextFormField>(
        find.byType(TextFormField),
      );
      expect(fields.map((f) => f.controller!.text), ['', '']);
    });
  });
}
