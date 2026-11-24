import 'package:flutter_test/flutter_test.dart';
import 'package:sulyukta_taxi/services/gps_fix_policy.dart';

void main() {
  group('GPS fix acceptance policy', () {
    final now = DateTime.utc(2026, 11, 24, 9);

    test('accepts a fresh coordinate with useful accuracy', () {
      expect(isUsableGpsFix(
        latitude: 39.93, longitude: 69.59, accuracyMeters: 18,
        timestamp: now, now: now,
      ), isTrue);
    });

    test('accepts exact coordinate and accuracy boundaries', () {
      expect(isUsableGpsFix(
        latitude: -90, longitude: 180, accuracyMeters: 250,
        timestamp: now.subtract(const Duration(seconds: 60)), now: now,
      ), isTrue);
    });

    test('rejects non-finite and out-of-range coordinates', () {
      for (final point in <List<double>>[
        [double.nan, 0], [0, double.infinity], [90.01, 0], [0, -180.01],
      ]) {
        expect(isUsableGpsFix(
          latitude: point[0], longitude: point[1], accuracyMeters: 10,
          timestamp: now, now: now,
        ), isFalse);
      }
    });

    test('rejects missing, negative, non-finite or excessive accuracy', () {
      for (final accuracy in <double>[
        double.nan, double.infinity, -1, 250.001,
      ]) {
        expect(isUsableGpsFix(
          latitude: 39.93, longitude: 69.59, accuracyMeters: accuracy,
          timestamp: now, now: now,
        ), isFalse);
      }
    });

    test('rejects a missing GPS timestamp', () {
      expect(isUsableGpsFix(
        latitude: 39.93, longitude: 69.59, accuracyMeters: 10,
        timestamp: null, now: now,
      ), isFalse);
    });

    test('rejects a cached fix older than sixty seconds', () {
      expect(isUsableGpsFix(
        latitude: 39.93, longitude: 69.59, accuracyMeters: 10,
        timestamp: now.subtract(const Duration(seconds: 60, milliseconds: 1)),
        now: now,
      ), isFalse);
    });

    test('rejects a GPS timestamp in the future', () {
      expect(isUsableGpsFix(
        latitude: 39.93, longitude: 69.59, accuracyMeters: 10,
        timestamp: now.add(const Duration(milliseconds: 1)), now: now,
      ), isFalse);
    });

    test('honors a stricter caller-supplied accuracy limit', () {
      expect(isUsableGpsFix(
        latitude: 39.93, longitude: 69.59, accuracyMeters: 80,
        timestamp: now, now: now, maxAccuracyMeters: 50,
      ), isFalse);
    });

    test('rejects invalid maximum accuracy and age limits', () {
      expect(isUsableGpsFix(
        latitude: 39.93, longitude: 69.59, accuracyMeters: 10,
        timestamp: now, now: now, maxAccuracyMeters: double.infinity,
      ), isFalse);
      expect(isUsableGpsFix(
        latitude: 39.93, longitude: 69.59, accuracyMeters: 10,
        timestamp: now, now: now, maxAge: const Duration(seconds: -1),
      ), isFalse);
    });
  });
}
