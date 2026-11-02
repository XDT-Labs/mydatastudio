import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/file_sources/sync_folder/sync_folder_detector.dart';
import 'package:mydatastudio/modules/files/pages/new_file_collection_page.dart';

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
const _dropbox = DetectedSyncFolder(
  provider: SyncProvider.dropbox,
  displayName: 'Dropbox',
  path: '/Users/me/Library/CloudStorage/Dropbox',
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<DetectedSyncFolder> found,
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

  testWidgets('renders all three section headers', (tester) async {
    await pump(tester, found: [_icloud]);
    expect(find.text('Found on this Mac'), findsOneWidget);
    expect(find.text('Connect an account'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Dropbox'), findsNothing);
  });

  testWidgets('lists detected folders with an Add action', (tester) async {
    await pump(tester, found: [_icloud, _dropbox]);
    expect(find.text('iCloud Drive'), findsOneWidget);
    expect(find.text(_icloud.path), findsOneWidget);
    expect(find.text('Dropbox'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add'), findsNWidgets(2));
  });

  testWidgets('hides folders that are already a collection', (tester) async {
    await pump(tester, found: [_icloud, _dropbox], existing: {_icloud.path});
    expect(find.text('iCloud Drive'), findsNothing);
    expect(find.text('Dropbox'), findsOneWidget);
  });

  testWidgets('shows empty state when nothing is found', (tester) async {
    await pump(tester, found: const []);
    expect(
      find.text('No cloud sync folders found on this Mac.'),
      findsOneWidget,
    );
  });

  testWidgets('hides folders nested under an existing collection path', (
    tester,
  ) async {
    const nested = DetectedSyncFolder(
      provider: SyncProvider.googleDrive,
      displayName: 'Google Drive - My Drive',
      path: '/Users/me/Library/CloudStorage/GoogleDrive-a@x.com/My Drive',
    );
    await pump(
      tester,
      found: [nested, _dropbox],
      existing: {'/Users/me/Library/CloudStorage/GoogleDrive-a@x.com/'},
    );
    expect(find.text('Google Drive - My Drive'), findsNothing);
    expect(find.text('Dropbox'), findsOneWidget);
  });

  testWidgets('shows empty state when the lookup throws', (tester) async {
    await pump(
      tester,
      found: [_icloud],
      existingPaths: () async => throw Exception('db down'),
    );
    expect(find.text('iCloud Drive'), findsNothing);
    expect(
      find.text('No cloud sync folders found on this Mac.'),
      findsOneWidget,
    );
  });
}
