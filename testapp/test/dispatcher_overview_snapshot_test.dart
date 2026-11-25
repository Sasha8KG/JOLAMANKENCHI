import 'package:flutter_test/flutter_test.dart';
import 'package:sulyukta_taxi/services/dispatcher_overview_snapshot.dart';

void main() {
  Map<String, dynamic> validPayload() => {
    'drivers': [{'uid': 'driver_1', 'online': 1}],
    'orders': [{'id': 'order_1', 'status': 'new'}],
    'today': [{'status': 'new', 'count': 2}],
    'earnings': [{'driver_uid': 'driver_1', 'earned_som': 500}],
    'closed_shifts': [{'id': 'shift_1'}],
    'business_date': '2026-11-24',
  };

  group('Dispatcher overview snapshot', () {
    test('accepts a complete valid dashboard response', () {
      final snapshot = DispatcherOverviewSnapshot.parse(validPayload());
      expect(snapshot.drivers.single['uid'], 'driver_1');
      expect(snapshot.orders.single['id'], 'order_1');
      expect(snapshot.today.single['count'], 2);
      expect(snapshot.earnings.single['earned_som'], 500);
      expect(snapshot.closedShifts, hasLength(1));
      expect(snapshot.businessDate, '2026-11-24');
    });

    test('accepts an older Worker response without optional closed shift history', () {
      final payload = validPayload()..remove('closed_shifts');
      final snapshot = DispatcherOverviewSnapshot.parse(payload);
      expect(snapshot.closedShifts, isEmpty);
    });

    test('accepts null optional closed shift history as empty', () {
      final payload = validPayload()..['closed_shifts'] = null;
      final snapshot = DispatcherOverviewSnapshot.parse(payload);
      expect(snapshot.closedShifts, isEmpty);
    });

    test('uses the local date when an older Worker omits business_date', () {
      final payload = validPayload()..remove('business_date');
      final snapshot = DispatcherOverviewSnapshot.parse(payload);
      final now = DateTime.now();
      expect(snapshot.businessDate, '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}');
    });
    test('rejects a missing required dashboard list', () {
      final payload = validPayload()..remove('drivers');
      expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
    });

    test('rejects a non-list dashboard section', () {
      final payload = validPayload()..['orders'] = 'not-a-list';
      expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
    });

    test('rejects a malformed row instead of silently dropping it', () {
      final payload = validPayload()..['drivers'] = [{'uid': 'driver_1'}, 'bad-row'];
      expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
    });

    test('rejects duplicate driver UIDs', () {
      final payload = validPayload()..['drivers'] = [
        {'uid': 'driver_1'}, {'uid': 'driver_1'}
      ];
      expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
    });

    test('rejects duplicate order IDs', () {
      final payload = validPayload()..['orders'] = [
        {'id': 'order_1'}, {'id': 'order_1'}
      ];
      expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
    });

    test('rejects unsafe driver and order identifiers', () {
      for (final id in ['', 'bad/id', 'x' * 129]) {
        final payload = validPayload()..['orders'] = [{'id': id}];
        expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
      }
    });

    test('rejects more than the server page size of 100 orders', () {
      final payload = validPayload()
        ..['orders'] = List.generate(101, (index) => {'id': 'order_$index'});
      expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
    });

    test('rejects negative, fractional and non-finite status counts', () {
      for (final count in [-1, 1.5, double.nan, double.infinity]) {
        final payload = validPayload()..['today'] = [{'status': 'new', 'count': count}];
        expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
      }
    });

    test('rejects invalid business dates', () {
      for (final date in ['2026-13-40', '24-11-2026', '2026-11-24T09:00:00Z']) {
        final payload = validPayload()..['business_date'] = date;
        expect(() => DispatcherOverviewSnapshot.parse(payload), throwsFormatException);
      }
    });

    test('returns immutable row maps and lists', () {
      final snapshot = DispatcherOverviewSnapshot.parse(validPayload());
      expect(() => snapshot.drivers.add({'uid': 'driver_2'}), throwsUnsupportedError);
      expect(() => snapshot.drivers.single['online'] = 0, throwsUnsupportedError);
    });

    test('accepts an empty but complete dashboard response', () {
      final payload = validPayload()
        ..['drivers'] = <dynamic>[]
        ..['orders'] = <dynamic>[]
        ..['today'] = <dynamic>[]
        ..['earnings'] = <dynamic>[]
        ..['closed_shifts'] = <dynamic>[];
      final snapshot = DispatcherOverviewSnapshot.parse(payload);
      expect(snapshot.drivers, isEmpty);
      expect(snapshot.orders, isEmpty);
    });
  });
}
