import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';

/// The Locations drawer offers two ways to say "show me this place", and the
/// filter has to keep them apart.
void main() {
  const chicago = PhotoPlaceFilter(
    label: 'Chicago, Illinois, United States',
    latitude: 41.85003,
    longitude: -87.65005,
  );

  group('PhotoFilter place and landmark', () {
    test('a searched place replaces a landmark rather than adding to it', () {
      // Both narrow by location, but one matches coordinates and the other a
      // name the image analysis wrote. Applied together they ask for photos
      // near Chicago that are *also* tagged with an unrelated landmark, which
      // is nothing — the grid emptied when a city was searched while a
      // landmark from the list was still selected.
      const withLandmark = PhotoFilter(location: 'Eiffel Tower');

      final withPlace = withLandmark.copyWith(place: chicago, location: null);

      expect(withPlace.place, chicago);
      expect(withPlace.location, isNull);
    });

    test('clearing the location filter clears both kinds at once', () {
      const both = PhotoFilter(place: chicago, location: 'Eiffel Tower');

      final cleared = both.copyWith(place: null, location: null);

      expect(cleared.place, isNull);
      expect(cleared.location, isNull);
    });

    test('applying a place keeps unrelated filters', () {
      // Location narrows what is already on screen; it is not a reset.
      const filter = PhotoFilter(
        onlyFavorites: true,
        collectionId: 'col-1',
        searchQuery: 'beach',
      );

      final narrowed = filter.copyWith(place: chicago, location: null);

      expect(narrowed.onlyFavorites, isTrue);
      expect(narrowed.collectionId, 'col-1');
      expect(narrowed.searchQuery, 'beach');
      expect(narrowed.place, chicago);
    });

    test('a place survives a copyWith that does not mention it', () {
      const filter = PhotoFilter(place: chicago);

      expect(filter.copyWith(onlyFavorites: true).place, chicago);
    });
  });
}
