import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:jol_aman_kenchi/services/nearby_driver_filter.dart';

void main() {
  group('Nearby driver selection', () {
    final now = DateTime.utc(2026, 11, 24, 9);
    const pickup = LatLng(39.9380, 69.5650);

    test('rejects invalid pickup coordinates', () {
      expect(selectNearbyDriverLocations(
        pickup: const LatLng(91, 0),
        candidates: [MapEntry(pickup, now)],
        now: now,
      ), isEmpty);
    });

    test('rejects stale and invalid driver coordinates', () {
      final result = selectNearbyDriverLocations(
        pickup: pickup,
        candidates: [
          MapEntry(pickup, now.subtract(const Duration(seconds: 61))),
          MapEntry(const LatLng(91, 0), now),
          MapEntry(const LatLng(39.94, 69.57), now),
        ],
        now: now,
      );
      expect(result, hasLength(1));
      expect(result.single.key, const LatLng(39.94, 69.57));
    });

    test('sorts valid drivers by distance from pickup', () {
      final near = const LatLng(39.939, 69.565);
      final far = const LatLng(39.95, 69.565);
      final result = selectNearbyDriverLocations(
        pickup: pickup,
        candidates: [MapEntry(far, now), MapEntry(near, now)],
        now: now,
      );
      expect(result.map((entry) => entry.key).toList(), [near, far]);
    });

    test('limits the returned list to the requested maximum', () {
      final candidates = List.generate(
        12,
        (index) => MapEntry(
          LatLng(39.938 + index * 0.0001, 69.565),
          now,
        ),
      );
      expect(selectNearbyDriverLocations(
        pickup: pickup,
        candidates: candidates,
        now: now,
        maxResults: 3,
      ), hasLength(3));
    });

    test('prefers the fresher GPS fix for effectively equal distances', () {
      final older = now.subtract(const Duration(seconds: 20));
      final newer = now.subtract(const Duration(seconds: 2));
      final result = selectNearbyDriverLocations(
        pickup: pickup,
        candidates: [
          MapEntry(const LatLng(39.938001, 69.565), older),
          MapEntry(const LatLng(39.937999, 69.565), newer),
        ],
        now: now,
      );
      expect(result.first.value, newer);
    });
  });
}
