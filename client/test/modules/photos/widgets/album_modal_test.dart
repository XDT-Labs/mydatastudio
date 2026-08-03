import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/album_modal.dart';

class FakePhotosRepository extends PhotosRepository {
  List<({Album album, int count})> mockAlbums = [];
  Album? createdAlbum;
  List<(String fileId, String albumId)> addedFiles = [];

  @override
  Future<List<({Album album, int count})>> allAlbumsWithCounts() async {
    return mockAlbums;
  }

  @override
  Future<void> createAlbum(Album album) async {
    createdAlbum = album;
    mockAlbums.add((album: album, count: 0));
  }

  @override
  Future<void> addFileToAlbum(String fileId, String albumId) async {
    addedFiles.add((fileId, albumId));
  }
}

Widget createTestApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: darkColorScheme,
    ),
    home: Scaffold(
      body: child,
    ),
  );
}

void main() {
  late FakePhotosRepository fakeRepo;

  setUp(() {
    fakeRepo = FakePhotosRepository();
    fakeRepo.mockAlbums = [
      (album: Album(id: 'a1', name: 'Vacation 2025'), count: 5),
      (album: Album(id: 'a2', name: 'Family'), count: 12),
    ];
  });

  group('AlbumModal Widget Tests', () {
    testWidgets('renders both tab modes and switches between them', (tester) async {
      await tester.pumpWidget(createTestApp(
        AlbumModal(
          selectedFileIds: const {'f1', 'f2'},
          photosRepository: fakeRepo,
        ),
      ));
      await tester.pumpAndSettle();

      // Check header
      expect(find.text('Album Management'), findsOneWidget);
      expect(find.text('Add to Existing Album'), findsOneWidget);
      expect(find.text('Create New Album'), findsOneWidget);

      // Check existing albums list in mode 1
      expect(find.text('Vacation 2025'), findsOneWidget);
      expect(find.text('Family'), findsOneWidget);
      expect(find.text('Add to Album'), findsOneWidget);

      // Switch to Mode 2: Create New Album
      await tester.tap(find.text('Create New Album'));
      await tester.pumpAndSettle();

      expect(find.text('Album Title *'), findsOneWidget);
      expect(find.text('Description (Optional)'), findsOneWidget);
      expect(find.text('Create & Add'), findsOneWidget);
    });

    testWidgets('validates required album title on create new album submit', (tester) async {
      await tester.pumpWidget(createTestApp(
        AlbumModal(
          selectedFileIds: const {'f1'},
          initialMode: AlbumModalMode.createNew,
          photosRepository: fakeRepo,
        ),
      ));
      await tester.pumpAndSettle();

      // Tap Create & Add button without entering title
      await tester.tap(find.text('Create & Add'));
      await tester.pumpAndSettle();

      expect(find.text('Please enter an album title'), findsOneWidget);
      expect(fakeRepo.createdAlbum, isNull);
    });

    testWidgets('creates a new album and adds selected files', (tester) async {
      await tester.pumpWidget(createTestApp(
        AlbumModal(
          selectedFileIds: const {'f1', 'f2'},
          initialMode: AlbumModalMode.createNew,
          photosRepository: fakeRepo,
        ),
      ));
      await tester.pumpAndSettle();

      // Enter title and description
      await tester.enterText(find.byType(TextFormField).first, 'Road Trip');
      await tester.enterText(find.byType(TextFormField).last, 'California coast photos');
      await tester.pumpAndSettle();

      // Tap Create & Add
      await tester.tap(find.text('Create & Add'));
      await tester.pumpAndSettle();

      expect(fakeRepo.createdAlbum, isNotNull);
      expect(fakeRepo.createdAlbum!.name, 'Road Trip');
      expect(fakeRepo.createdAlbum!.description, 'California coast photos');
      expect(fakeRepo.createdAlbum!.coverFileId, 'f1');
      expect(fakeRepo.addedFiles.length, 2);
    });

    testWidgets('adds selected files to an existing album selection', (tester) async {
      await tester.pumpWidget(createTestApp(
        AlbumModal(
          selectedFileIds: const {'f10'},
          initialMode: AlbumModalMode.addToExisting,
          photosRepository: fakeRepo,
        ),
      ));
      await tester.pumpAndSettle();

      // Tap 'Vacation 2025' radio tile
      await tester.tap(find.text('Vacation 2025'));
      await tester.pumpAndSettle();

      // Tap Add to Album
      await tester.tap(find.text('Add to Album'));
      await tester.pumpAndSettle();

      expect(fakeRepo.addedFiles.length, 1);
      expect(fakeRepo.addedFiles.first, ('f10', 'a1'));
    });
  });
}
