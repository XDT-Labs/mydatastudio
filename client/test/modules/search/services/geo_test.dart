import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/services/geo.dart';

void main() {
  group('boundingBox', () {
    test('covers every point the radius reaches', () {
      // The contract that matters: a rectangle in degrees must over-cover a
      // circle in kilometres. Under-covering by even a rounding error silently
      // drops a genuine match, and nothing downstream can notice — the
      // haversine filter only ever removes rows the box let through.
      const lat = 51.17622; // Banff
      const lng = -115.56982;
      const radiusKm = 25.0;
      final box = GeoRadius.boundingBox(lat, lng, radiusKm);

      // Due north, south, east and west at exactly the radius.
      const metresPerDegreeLat = 111.32;
      final northLat = lat + radiusKm / metresPerDegreeLat;
      expect(box.maxLatitude, greaterThanOrEqualTo(northLat));
      expect(box.minLatitude, lessThanOrEqualTo(lat - radiusKm / metresPerDegreeLat));

      // A point due east at the radius must fall inside the longitude span.
      var eastLng = lng;
      while (GeoRadius.distanceKm(lat, lng, lat, eastLng) < radiusKm) {
        eastLng += 0.001;
      }
      expect(box.maxLongitude, greaterThanOrEqualTo(eastLng - 0.001));
    });

    test('longitude span widens with latitude for the same radius', () {
      // A degree of longitude shrinks towards the poles, so the same 25 km
      // spans more of them further north. Getting this backwards produces a box
      // that is too narrow exactly where photos of northern trips live.
      final equator = GeoRadius.boundingBox(0.0, 0.0, 25.0);
      final arctic = GeoRadius.boundingBox(70.0, 0.0, 25.0);

      final equatorSpan = equator.maxLongitude - equator.minLongitude;
      final arcticSpan = arctic.maxLongitude - arctic.minLongitude;
      expect(arcticSpan, greaterThan(equatorSpan));
    });

    test('falls back to the whole globe rather than wrapping past a pole', () {
      // BETWEEN cannot express a range that wraps: a min of -181 excludes
      // exactly the points nearest the wrap. Widening is the only safe answer,
      // and the haversine filter still makes the result exact.
      final box = GeoRadius.boundingBox(89.9, 10.0, 100.0);
      expect(box.minLongitude, -180.0);
      expect(box.maxLongitude, 180.0);
      expect(box.maxLatitude, lessThanOrEqualTo(90.0));
      expect(box.minLatitude, greaterThanOrEqualTo(-90.0));
    });

    test('falls back to the whole globe rather than wrapping the antimeridian', () {
      final box = GeoRadius.boundingBox(-16.5, 179.9, 200.0);
      expect(box.minLongitude, -180.0);
      expect(box.maxLongitude, 180.0);
    });
  });

  group('distanceKm', () {
    test('is zero at the same point without producing NaN', () {
      // The floating-point trap the min(1.0, ...) guard exists for: the cosine
      // terms sum to a hair above 1.0, acos of which is NaN, and every
      // comparison against NaN is false — so the row that matched best is the
      // one row silently dropped.
      final d = GeoRadius.distanceKm(51.17622, -115.56982, 51.17622, -115.56982);
      expect(d.isNaN, isFalse);
      expect(d, closeTo(0.0, 1e-6));
    });

    test('matches a known great-circle distance', () {
      // Banff to Calgary, ~114 km by great circle.
      final d = GeoRadius.distanceKm(51.17622, -115.56982, 51.05011, -114.08529);
      expect(d, closeTo(104.0, 6.0));
    });

    test('is symmetric', () {
      final ab = GeoRadius.distanceKm(51.5, -0.12, 48.85, 2.35);
      final ba = GeoRadius.distanceKm(48.85, 2.35, 51.5, -0.12);
      expect(ab, closeTo(ba, 1e-9));
    });
  });

  group('haversineSql', () {
    test('takes exactly as many parameters as it has placeholders', () {
      // These two are maintained together and bound positionally, so a
      // placeholder added to one and not the other shifts every later
      // parameter by a slot — which SQLite reports as a type error somewhere
      // unrelated, if it reports anything at all.
      final sql = GeoRadius.haversineSql('f.latitude', 'f.longitude');
      final placeholders = '?'.allMatches(sql).length;
      expect(placeholders, GeoRadius.haversineParams(1.0, 2.0).length);
    });
  });
}
