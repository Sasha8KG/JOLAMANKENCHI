import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:sulyukta_taxi/services/firebase_service.dart';
import 'package:sulyukta_taxi/services/route_service.dart';
import 'package:sulyukta_taxi/services/gps_freshness.dart';

void main() {
  group('Firebase phone login mapping', () {
    test('converts local Kyrgyz number to the internal login', () {
      expect(
        FirebaseService.phoneLoginEmail('0555123456'),
        'kg996555123456@jolamankenchi.app',
      );
    });

    test('accepts a number with the +996 country prefix', () {
      expect(
        FirebaseService.phoneLoginEmail('+996 555 123 456'),
        'kg996555123456@jolamankenchi.app',
      );
    });

    test('does not duplicate the 996 country prefix', () {
      expect(
        FirebaseService.phoneLoginEmail('996555123456'),
        'kg996555123456@jolamankenchi.app',
      );
    });
  });

  group('Kyrgyz phone validation', () {
    test('accepts the local format used on the registration form', () {
      expect(FirebaseService.isValidKgPhone('0700123456'), isTrue);
    });

    test('accepts the international format', () {
      expect(FirebaseService.isValidKgPhone('+996700123456'), isTrue);
    });

    test('ignores spaces, brackets and hyphens', () {
      expect(FirebaseService.isValidKgPhone('+996 (700) 123-456'), isTrue);
      expect(FirebaseService.isValidKgPhone('0700 123-456'), isTrue);
    });

    test('rejects incomplete and incorrectly prefixed numbers', () {
      expect(FirebaseService.isValidKgPhone('070012345'), isFalse);
      expect(FirebaseService.isValidKgPhone('+995700123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('abc'), isFalse);
    });
  });


  group('Strict Kyrgyz phone input validation', () {
    test('accepts local numbers with ordinary separators', () {
      expect(FirebaseService.isValidKgPhone('0700 123 456'), isTrue);
      expect(FirebaseService.isValidKgPhone('0700-123-456'), isTrue);
      expect(FirebaseService.isValidKgPhone('(0700) 123-456'), isTrue);
    });

    test('accepts international numbers with balanced parentheses', () {
      expect(FirebaseService.isValidKgPhone('+996 (700) 123-456'), isTrue);
      expect(FirebaseService.isValidKgPhone('996 700 123 456'), isTrue);
    });

    test('rejects alphabetic text around an otherwise valid number', () {
      expect(FirebaseService.isValidKgPhone('abc0700123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700123456xyz'), isFalse);
      expect(FirebaseService.isValidKgPhone('phone: 0700123456'), isFalse);
    });

    test('rejects a plus sign anywhere except the beginning', () {
      expect(FirebaseService.isValidKgPhone('0700+123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('++996700123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('996+700123456'), isFalse);
    });

    test('rejects unbalanced or nested parentheses', () {
      expect(FirebaseService.isValidKgPhone('(0700123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700123456)'), isFalse);
      expect(FirebaseService.isValidKgPhone('((0700))123456'), isFalse);
    });

    test('rejects punctuation that is not a phone separator', () {
      expect(FirebaseService.isValidKgPhone('0700.123.456'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700/123/456'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700,123,456'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700;123;456'), isFalse);
    });

    test('rejects control characters and whitespace injection', () {
      expect(FirebaseService.isValidKgPhone('0700\n123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700\t123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700\r123456'), isFalse);
    });

    test('rejects incorrect lengths and country prefixes', () {
      expect(FirebaseService.isValidKgPhone('070012345'), isFalse);
      expect(FirebaseService.isValidKgPhone('07001234567'), isFalse);
      expect(FirebaseService.isValidKgPhone('+995700123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('1700123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('99670012345'), isFalse);
      expect(FirebaseService.isValidKgPhone('9967001234567'), isFalse);
    });

    test('rejects empty input and input without digits', () {
      expect(FirebaseService.isValidKgPhone(''), isFalse);
      expect(FirebaseService.isValidKgPhone('   '), isFalse);
      expect(FirebaseService.isValidKgPhone('+++---()'), isFalse);
    });


    test('accepts local number with separated digits', () {
      expect(FirebaseService.isValidKgPhone('0 700 123 456'), isTrue);
    });

    test('accepts international number without plus sign', () {
      expect(FirebaseService.isValidKgPhone('996700123456'), isTrue);
    });

    test('trims whitespace before an international prefix', () {
      expect(FirebaseService.isValidKgPhone(' +996700123456'), isTrue);
    });

    test('accepts sequential parentheses but rejects nested parentheses', () {
      expect(FirebaseService.isValidKgPhone('(0700)(123)456'), isTrue);
      expect(FirebaseService.isValidKgPhone('0700((123))456'), isFalse);
    });

    test('rejects full-width unicode digits', () {
      expect(FirebaseService.isValidKgPhone('０７００１２３４５６'), isFalse);
    });

    test('accepts leading and trailing visual separators', () {
      expect(FirebaseService.isValidKgPhone('---0700123456'), isTrue);
      expect(FirebaseService.isValidKgPhone('0700123456---'), isTrue);
    });

    test('maps a parenthesized international number consistently', () {
      expect(
        FirebaseService.phoneLoginEmail('+996 (700) 123-456'),
        'kg996700123456@jolamankenchi.app',
      );
    });

    test('phone login mapping refuses text disguised as a phone number', () {
      expect(
        () => FirebaseService.phoneLoginEmail('abc0700123456'),
        throwsArgumentError,
      );
      expect(
        () => FirebaseService.phoneLoginEmail('0700123456xyz'),
        throwsArgumentError,
      );
    });
  });

  group('Kyrgyz phone validation regression matrix', () {
    final cases = <({String input, bool expected, String label})>[
      (input: ' 0700123456 ', expected: true, label: 'trims outer spaces'),
      (input: '0 700 123 456', expected: true, label: 'accepts separated local digits'),
      (input: '0700-123-456', expected: true, label: 'accepts local hyphens'),
      (input: ' (0700) 123-456 ', expected: true, label: 'accepts surrounding spaces and parentheses'),
      (input: '(0700)(123)456', expected: true, label: 'accepts sequential balanced parentheses'),
      (input: '+996700123456', expected: true, label: 'accepts international prefix with plus'),
      (input: '996700123456', expected: true, label: 'accepts international prefix without plus'),
      (input: '+996 (700) 123-456', expected: true, label: 'accepts international visual separators'),
      (input: '---0700123456', expected: true, label: 'accepts leading hyphen separators under current rules'),
      (input: '0700123456---', expected: true, label: 'accepts trailing hyphen separators under current rules'),
      (input: '   ', expected: false, label: 'rejects whitespace only'),
      (input: 'abc0700123456', expected: false, label: 'rejects alphabetic prefix'),
      (input: '0700123456xyz', expected: false, label: 'rejects alphabetic suffix'),
      (input: '0700+123456', expected: false, label: 'rejects plus in the middle'),
      (input: '++996700123456', expected: false, label: 'rejects repeated plus signs'),
      (input: '(0700123456', expected: false, label: 'rejects an unclosed parenthesis'),
      (input: '0700123456)', expected: false, label: 'rejects an unmatched closing parenthesis'),
      (input: '((0700))123456', expected: false, label: 'rejects nested parentheses'),
      (input: '0700.123.456', expected: false, label: 'rejects periods'),
      (input: '0700/123/456', expected: false, label: 'rejects slashes'),
      (input: '0700,123,456', expected: false, label: 'rejects commas'),
      (input: '0700;123;456', expected: false, label: 'rejects semicolons'),
      (input: '0700\n123456', expected: false, label: 'rejects line feeds'),
      (input: '0700\t123456', expected: false, label: 'rejects tabs'),
      (input: '0700\r123456', expected: false, label: 'rejects carriage returns'),
      (input: '０７００１２３４５６', expected: false, label: 'rejects full-width Unicode digits'),
      (input: '070012345', expected: false, label: 'rejects a number that is too short'),
      (input: '07001234567', expected: false, label: 'rejects a number that is too long'),
      (input: '+995700123456', expected: false, label: 'rejects a foreign country prefix'),
      (input: '1700123456', expected: false, label: 'rejects an invalid local prefix'),
    ];
    for (final item in cases) {
      test(item.label, () {
        expect(FirebaseService.isValidKgPhone(item.input), item.expected,
            reason: 'Input: ${item.input}');
      });
    }
  });

  group('Road route validation and labels', () {
    const validPoint = LatLng(39.92764, 69.58843);

    test('returns a zero-length route for identical points without network access', () async {
      final route = await RouteService.drivingRoute(validPoint, validPoint);
      expect(route.points, [validPoint, validPoint]);
      expect(route.distanceMeters, 0);
      expect(route.durationSeconds, 0);
    });

    test('returns a zero-length route for points less than one metre apart', () async {
      final nearbyPoint = LatLng(39.9276401, 69.5884301);
      final route = await RouteService.drivingRoute(validPoint, nearbyPoint);
      expect(route.distanceMeters, 0);
      expect(route.durationSeconds, 0);
    });

    final invalidPoints = <({String label, LatLng point})>[
      (label: 'rejects latitude above 90 degrees', point: const LatLng(90.01, 0)),
      (label: 'rejects latitude below -90 degrees', point: const LatLng(-90.01, 0)),
      (label: 'rejects longitude above 180 degrees', point: const LatLng(0, 180.01)),
      (label: 'rejects longitude below -180 degrees', point: const LatLng(0, -180.01)),
      (label: 'rejects NaN latitude', point: LatLng(double.nan, 0)),
      (label: 'rejects infinite longitude', point: LatLng(0, double.infinity)),
    ];

    for (final item in invalidPoints) {
      test(item.label, () async {
        expect(
          () => RouteService.drivingRoute(validPoint, item.point),
          throwsA(isA<FormatException>()),
        );
      });
    }

    final distanceCases = <({double meters, String expected})>[
      (meters: 0, expected: '0 м'),
      (meters: 125, expected: '125 м'),
      (meters: 999, expected: '999 м'),
      (meters: 1000, expected: '1.0 км'),
      (meters: 1500, expected: '1.5 км'),
      (meters: 12500, expected: '12.5 км'),
    ];

    for (final item in distanceCases) {
      test('formats distance ${item.meters} metres', () {
        final route = RoadRoute(
          points: const [validPoint, validPoint],
          distanceMeters: item.meters,
          durationSeconds: 0,
        );
        expect(route.distanceLabel, item.expected);
      });
    }

    final etaCases = <({double seconds, String expected})>[
      (seconds: 0, expected: '0 мин'),
      (seconds: 30, expected: '1 мин'),
      (seconds: 59, expected: '1 мин'),
      (seconds: 60, expected: '1 мин'),
      (seconds: 1800, expected: '30 мин'),
      (seconds: 3600, expected: '1 ч 0 мин'),
      (seconds: 3660, expected: '1 ч 1 мин'),
    ];

    for (final item in etaCases) {
      test('formats travel time ${item.seconds} seconds', () {
        final route = RoadRoute(
          points: const [validPoint, validPoint],
          distanceMeters: 0,
          durationSeconds: item.seconds,
        );
        expect(route.etaLabel, item.expected);
      });
    }
  });

  group('Driver GPS freshness', () {
    final now = DateTime.utc(2026, 11, 23, 12);

    test('parses Unix timestamps in seconds from the Worker', () {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(1795435140 * 1000);
      expect(parseGpsTimestamp(1795435140), timestamp);
    });

    test('parses ISO timestamps returned by compatible API responses', () {
      expect(
        parseGpsTimestamp('2026-11-23T12:00:00Z'),
        DateTime.utc(2026, 11, 23, 12),
      );
    });

    test('rejects missing or malformed timestamps', () {
      expect(parseGpsTimestamp(null), isNull);
      expect(parseGpsTimestamp('not-a-date'), isNull);
    });

    test('rejects non-finite numeric GPS timestamps', () {
      expect(parseGpsTimestamp(double.nan), isNull);
      expect(parseGpsTimestamp(double.infinity), isNull);
      expect(parseGpsTimestamp(double.negativeInfinity), isNull);
    });

    test('rejects numeric GPS timestamps outside the DateTime range', () {
      expect(parseGpsTimestamp(8640000000001), isNull);
      expect(parseGpsTimestamp(-8640000000001), isNull);
      expect(parseGpsTimestamp(double.maxFinite), isNull);
    });

    test('accepts a GPS update exactly at the 60-second limit', () {
      expect(
        isGpsTimestampFresh(now.subtract(const Duration(seconds: 60)), now: now),
        isTrue,
      );
    });

    test('rejects GPS older than 60 seconds', () {
      expect(
        isGpsTimestampFresh(now.subtract(const Duration(seconds: 61)), now: now),
        isFalse,
      );
    });

    test('rejects timestamps from the future', () {
      expect(
        isGpsTimestampFresh(now.add(const Duration(seconds: 1)), now: now),
        isFalse,
      );
    });

    test('rejects a missing timestamp', () {
      expect(isGpsTimestampFresh(null, now: now), isFalse);
      expect(calculateGpsAgeSeconds(null, now: now), isNull);
    });

    test('reports age in whole seconds consistently', () {
      expect(
        calculateGpsAgeSeconds(now.subtract(const Duration(seconds: 17)), now: now),
        17,
      );
    });
  });

}
