import 'package:flutter_test/flutter_test.dart';
import 'package:sulyukta_taxi/services/route_cache_policy.dart';

void main() {
  group('Route cache policy', () {
    final now = DateTime.utc(2026, 11, 24, 9);

    test('reuses a matching route inside the two-minute window', () {
      expect(RouteCachePolicy.isFresh(
        cachedKey: 'order:pickup:driver',
        requestedKey: 'order:pickup:driver',
        fetchedAt: now.subtract(const Duration(minutes: 1)),
        now: now,
      ), isTrue);
    });

    test('rejects a route after its maximum age', () {
      expect(RouteCachePolicy.isFresh(
        cachedKey: 'same',
        requestedKey: 'same',
        fetchedAt: now.subtract(const Duration(minutes: 2, seconds: 1)),
        now: now,
      ), isFalse);
    });

    test('rejects a route from a different order or coordinate key', () {
      expect(RouteCachePolicy.isFresh(
        cachedKey: 'old-order',
        requestedKey: 'new-order',
        fetchedAt: now,
        now: now,
      ), isFalse);
    });

    test('rejects future-dated cache entries', () {
      expect(RouteCachePolicy.isFresh(
        cachedKey: 'same',
        requestedKey: 'same',
        fetchedAt: now.add(const Duration(seconds: 1)),
        now: now,
      ), isFalse);
    });
  });
}
