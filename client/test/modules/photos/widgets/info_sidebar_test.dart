import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/tag_chip.dart';
import 'package:mydatastudio/modules/photos/widgets/sidebar/info_sidebar.dart';

class FakePhotosRepository extends PhotosRepository {
  List<String> tags = [];
  List<Album> albums = [];
  Set<String> fileAlbumIds = {};
  String? updatedFileName;
  bool isDeleted = false;
  String? addedTag;
  String? removedTag;

  @override
  Future<List<String>> getTagsForFile(String fileId) async => tags;

  @override
  Future<List<Album>> allAlbums() async => albums;

  @override
  Future<List<Album>> getAlbumsForFile(String fileId) async {
    return albums.where((a) => fileAlbumIds.contains(a.id)).toList();
  }

  @override
  Future<void> addTag(String fileId, String tag) async {
    addedTag = tag;
    if (!tags.contains(tag)) tags.add(tag);
  }

  @override
  Future<void> removeTag(String fileId, String tag) async {
    removedTag = tag;
    tags.remove(tag);
  }

  @override
  Future<void> updateFileName(String fileId, String newName) async {
    updatedFileName = newName;
  }

  @override
  Future<void> deleteFile(String fileId) async {
    isDeleted = true;
  }
}

File _createTestFile() {
  return File(
    id: 'f1',
    name: 'sunset_beach.jpg',
    path: '/photos/sunset_beach.jpg',
    parent: '/photos',
    dateCreated: DateTime(2026, 7, 15, 14, 30),
    dateLastModified: DateTime(2026, 7, 15, 14, 30),
    collectionId: 'col-photos',
    contentType: 'image/jpeg',
    size: 2457600, // ~2.3 MB
    isDeleted: false,
    latitude: 34.0522,
    longitude: -118.2437,
  );
}

Widget _buildTestableWidget(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(
      body: SizedBox(
        width: 320,
        height: 800,
        child: child,
      ),
    ),
  );
}

void main() {
  tearDown(() {
    ViewStateService.instance.setInfoMedia(null);
    ViewStateService.instance.isInfoOpen.add(false);
  });

  testWidgets('renders metadata for a given file', (WidgetTester tester) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);
    ViewStateService.instance.isInfoOpen.add(true);

    final fakeRepo = FakePhotosRepository();
    fakeRepo.tags = ['beach', 'sunset'];
    fakeRepo.albums = [Album(id: 'a1', name: 'Summer 2026')];

    await tester.pumpWidget(_buildTestableWidget(InfoSidebar(repository: fakeRepo)));
    await tester.pumpAndSettle();

    // Verify title and header
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('sunset_beach.jpg'), findsOneWidget);

    // Verify metadata rows
    expect(find.text('Information'), findsOneWidget);
    expect(find.text('Resolution'), findsOneWidget);
    expect(find.text('2.3 MB'), findsOneWidget);
    expect(find.text('image/jpeg'), findsOneWidget);
    expect(find.text('34.0522, -118.2437'), findsOneWidget);
    expect(find.text('col-photos'), findsOneWidget);

    // Verify action buttons
    expect(find.text('Open in Finder'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('close button calls the close handler', (WidgetTester tester) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);
    ViewStateService.instance.isInfoOpen.add(true);

    final fakeRepo = FakePhotosRepository();

    await tester.pumpWidget(_buildTestableWidget(InfoSidebar(repository: fakeRepo)));
    await tester.pumpAndSettle();

    expect(ViewStateService.instance.isInfoOpen.value, isTrue);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(ViewStateService.instance.isInfoOpen.value, isFalse);
  });

  testWidgets('tag chips display correctly', (WidgetTester tester) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);

    final fakeRepo = FakePhotosRepository();
    fakeRepo.tags = ['nature', 'ocean'];

    await tester.pumpWidget(_buildTestableWidget(InfoSidebar(repository: fakeRepo)));
    await tester.pumpAndSettle();

    expect(find.text('Tags (2)'), findsOneWidget);
    expect(find.byType(TagChip), findsNWidgets(2));
    expect(find.text('#nature'), findsOneWidget);
    expect(find.text('#ocean'), findsOneWidget);
  });

  testWidgets('add tag input and button adds a new tag', (WidgetTester tester) async {
    final testFile = _createTestFile();
    ViewStateService.instance.setInfoMedia(testFile);

    final fakeRepo = FakePhotosRepository();

    await tester.pumpWidget(_buildTestableWidget(InfoSidebar(repository: fakeRepo)));
    await tester.pumpAndSettle();

    final tagInput = find.byType(TextField);
    await tester.enterText(tagInput, 'vacation');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(fakeRepo.addedTag, equals('vacation'));
    expect(find.text('#vacation'), findsOneWidget);
  });
}
