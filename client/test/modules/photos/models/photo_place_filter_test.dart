import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';

/// The bounding box is the whole location filter — get it wrong and "photos
/// near Austin" silently returns the wrong set with nothing to indicate it.
void main() {
  group('PhotoPlaceFilter.boundingBox', () {
    test('spans roughly the requested radius north and south', () {
      const filter = PhotoPlaceFilter(
        label: 'Austin',
        latitude: 30.26715,
        longitude: -97.74306,
        radiusKm: 50,
      );

      final box = filter.boundingBox;

      // 50 km is ~0.45° of latitude anywhere on Earth.
      expect(box.maxLat - box.minLat, closeTo(0.90, 0.02));
      expect((box.maxLat + box.minLat) / 2, closeTo(30.26715, 0.001));
    });

    test('widens the longitude span as latitude increases', () {
      // Meridians converge toward the poles, so a fixed radius covers more
      // degrees of longitude further north. Using a constant span instead
      // would quietly under-select every high-latitude search — a 50 km
      // search around Tromsø would cover about 20 km of longitude.
      const equator = PhotoPlaceFilter(
        label: 'Quito',
        latitude: 0.0,
        longitude: 0.0,
        radiusKm: 50,
      );
      const northern = PhotoPlaceFilter(
        label: 'Tromsø',
        latitude: 69.65,
        longitude: 18.96,
        radiusKm: 50,
      );

      final equatorSpan = equator.boundingBox.maxLng - equator.boundingBox.minLng;
      final northernSpan =
          northern.boundingBox.maxLng - northern.boundingBox.minLng;

      expect(northernSpan, greaterThan(equatorSpan * 2));
    });

    test('does not ask for an unbounded span at the pole', () {
      // cos(90°) is 0; dividing by it yields infinity, and an infinite
      // longitude bound turns the query into a full table scan that matches
      // nothing sane.
      const filter = PhotoPlaceFilter(
        label: 'Pole',
        latitude: 89.999,
        longitude: 0.0,
        radiusKm: 50,
      );

      final box = filter.boundingBox;

      expect(box.minLng, greaterThanOrEqualTo(-180.0));
      expect(box.maxLng, lessThanOrEqualTo(180.0));
      expect(box.maxLat, lessThanOrEqualTo(90.0));
    });

    test('flags a box that straddles the antimeridian', () {
      // Around Fiji the raw bounds run past +180. Treated as a plain BETWEEN
      // range that is `minLng > maxLng`, which matches zero rows — the filter
      // would look broken rather than wrong.
      const filter = PhotoPlaceFilter(
        label: 'Suva',
        latitude: -18.14,
        longitude: 178.44,
        radiusKm: 250,
      );

      final box = filter.boundingBox;

      expect(box.wrapsAntimeridian, isTrue);
      expect(box.normalizedMaxLng, lessThan(0));
      expect(box.normalizedMinLng, greaterThan(0));
    });

    test('an ordinary mid-map box does not claim to wrap', () {
      const filter = PhotoPlaceFilter(
        label: 'Austin',
        latitude: 30.26715,
        longitude: -97.74306,
      );

      expect(filter.boundingBox.wrapsAntimeridian, isFalse);
    });

    test('copyWith changes the radius and keeps the place', () {
      const filter = PhotoPlaceFilter(
        label: 'Austin, Texas, United States',
        latitude: 30.26715,
        longitude: -97.74306,
      );

      final wider = filter.copyWith(radiusKm: 100);

      expect(wider.radiusKm, 100);
      expect(wider.label, filter.label);
      expect(wider.latitude, filter.latitude);
      expect(wider.longitude, filter.longitude);
    });
  });
}
