import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/pages/album_detail_page.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';

class FakePhotosRepository extends PhotosRepository {
  Album? testAlbum;
  List<File> albumFiles = [];
  bool albumDeleted = false;
  (String id, String name, String? desc)? updatedAlbum;

  PhotoFilter? capturedFilter;

  @override
  Future<Album?> getAlbum(String albumId) async => testAlbum;

  @override
  Future<List<File>> photos({PhotoFilter? filter}) async {
    capturedFilter = filter;
    if (filter != null && filter.albumId == testAlbum?.id) {
      return albumFiles;
    }
    return [];
  }

  @override
  Future<void> updateAlbum(String albumId, String name, String? description) async {
    updatedAlbum = (albumId, name, description);
    testAlbum = Album(id: albumId, name: name, description: description);
  }

  @override
  Future<void> deleteAlbum(String albumId) async {
    albumDeleted = true;
  }
}

File _createTestFile(String id, String name) {
  return File(
    id: id,
    name: name,
    path: '/photos/$name',
    parent: '/photos',
    dateCreated: DateTime(2026, 7, 15),
    dateLastModified: DateTime(2026, 7, 15),
    collectionId: 'col1',
    contentType: 'image/jpeg',
    size: 1024,
    isDeleted: false,
  );
}

Widget createTestApp(Widget child) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => child,
      ),
      GoRoute(
        path: '/photos',
        builder: (context, state) => const Scaffold(body: Text('Photos')),
      ),
    ],
  );

  return MaterialApp.router(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: darkColorScheme,
    ),
    routerConfig: router,
  );
}

void main() {
  late FakePhotosRepository fakeRepo;

  setUp(() {
    fakeRepo = FakePhotosRepository();
    fakeRepo.testAlbum = Album(
      id: 'a100',
      name: 'Summer Trip 2026',
      description: 'Photos from the beach trip',
    );
    fakeRepo.albumFiles = [
      _createTestFile('f1', 'beach1.jpg'),
      _createTestFile('f2', 'sunset.jpg'),
    ];
  });

  group('AlbumDetailPage Widget Tests', () {
    testWidgets('renders album header title, description, and photo count', (tester) async {
      await tester.pumpWidget(createTestApp(
        AlbumDetailPage(
          albumId: 'a100',
          photosRepository: fakeRepo,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Summer Trip 2026'), findsOneWidget);
      expect(find.text('Photos from the beach trip'), findsOneWidget);
      expect(find.text('2 photos'), findsOneWidget);
      expect(fakeRepo.capturedFilter, isNotNull);
      expect(fakeRepo.capturedFilter!.albumId, equals('a100'));
    });

    testWidgets('shows edit album dialog and updates title and description', (tester) async {
      await tester.pumpWidget(createTestApp(
        AlbumDetailPage(
          albumId: 'a100',
          photosRepository: fakeRepo,
        ),
      ));
      await tester.pumpAndSettle();

      // Tap Edit icon button
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Edit Album'), findsOneWidget);

      // Change title
      await tester.enterText(find.byType(TextField).first, 'Updated Summer Trip');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(fakeRepo.updatedAlbum, isNotNull);
      expect(fakeRepo.updatedAlbum!.$2, 'Updated Summer Trip');
    });

    testWidgets('shows delete album dialog and deletes album when confirmed', (tester) async {
      await tester.pumpWidget(createTestApp(
        AlbumDetailPage(
          albumId: 'a100',
          photosRepository: fakeRepo,
        ),
      ));
      await tester.pumpAndSettle();

      // Tap Delete icon button
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.text('Delete Album'), findsOneWidget);

      // Confirm delete
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(fakeRepo.albumDeleted, isTrue);
    });
  });
}
