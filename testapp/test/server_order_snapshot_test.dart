import 'package:flutter_test/flutter_test.dart';
import 'package:sulyukta_taxi/services/server_order_snapshot.dart';

void main() {
  Map<String, dynamic> order(String id, String status) =>
      {'id': id, 'status': status, 'pickup_lat': 39.9, 'pickup_lng': 69.6};

  group('Server order snapshot validation', () {
    test('accepts a valid empty snapshot', () {
      final snapshot = ServerOrderSnapshot.parse({
        'orders': <dynamic>[],
        'assignedOrders': <dynamic>[],
      });
      expect(snapshot.openOrders, isEmpty);
      expect(snapshot.assignedOrders, isEmpty);
    });

    test('normalizes valid free and assigned orders', () {
      final snapshot = ServerOrderSnapshot.parse({
        'orders': [order('open_1', 'new')],
        'assignedOrders': [order('active_1', 'driver_assigned')],
      });
      expect(snapshot.openOrders.single['id'], 'open_1');
      expect(snapshot.assignedOrders.single['id'], 'active_1');
    });

    test('uses Firebase order id when the local id is absent', () {
      final snapshot = ServerOrderSnapshot.parse({
        'orders': [{'firebase_order_id': 'firebase_123', 'status': 'new'}],
        'assignedOrders': <dynamic>[],
      });
      expect(snapshot.openOrders.single['id'], 'firebase_123');
    });

    test('rejects a missing free-order list', () {
      expect(() => ServerOrderSnapshot.parse({'assignedOrders': <dynamic>[]}), throwsFormatException);
    });

    test('rejects a missing assigned-order list', () {
      expect(() => ServerOrderSnapshot.parse({'orders': <dynamic>[]}), throwsFormatException);
    });

    test('rejects non-map order entries instead of silently dropping them', () {
      expect(() => ServerOrderSnapshot.parse({
        'orders': [order('one', 'new'), 'corrupt'],
        'assignedOrders': <dynamic>[],
      }), throwsFormatException);
    });

    test('rejects malformed and overlong order ids', () {
      for (final id in ['', 'bad/id', 'has space', 'x' * 129]) {
        expect(() => ServerOrderSnapshot.parse({
          'orders': [order(id, 'new')],
          'assignedOrders': <dynamic>[],
        }), throwsFormatException);
      }
    });

    test('rejects duplicate free order ids', () {
      expect(() => ServerOrderSnapshot.parse({
        'orders': [order('same', 'new'), order('same', 'new')],
        'assignedOrders': <dynamic>[],
      }), throwsFormatException);
    });

    test('rejects more than one assigned order', () {
      expect(() => ServerOrderSnapshot.parse({
        'orders': <dynamic>[],
        'assignedOrders': [order('one', 'driver_assigned'), order('two', 'arrived')],
      }), throwsFormatException);
    });

    test('rejects an invalid free-order status', () {
      expect(() => ServerOrderSnapshot.parse({
        'orders': [order('one', 'arrived')],
        'assignedOrders': <dynamic>[],
      }), throwsFormatException);
    });

    test('rejects an invalid assigned-order status', () {
      expect(() => ServerOrderSnapshot.parse({
        'orders': <dynamic>[],
        'assignedOrders': [order('one', 'new')],
      }), throwsFormatException);
    });

    test('rejects the same order appearing in both lists', () {
      expect(() => ServerOrderSnapshot.parse({
        'orders': [order('same', 'new')],
        'assignedOrders': [order('same', 'driver_assigned')],
      }), throwsFormatException);
    });

    test('rejects more than the Worker maximum of 100 open offers', () {
      expect(() => ServerOrderSnapshot.parse({
        'orders': List.generate(101, (index) => order('o_$index', 'new')),
        'assignedOrders': <dynamic>[],
      }), throwsFormatException);
    });

    test('returns unmodifiable snapshot lists', () {
      final snapshot = ServerOrderSnapshot.parse({
        'orders': [order('one', 'new')],
        'assignedOrders': <dynamic>[],
      });
      expect(() => snapshot.openOrders.add(order('two', 'new')), throwsUnsupportedError);
    });
  });
}
