import 'package:flutter_test/flutter_test.dart';
import 'package:sulyukta_taxi/services/refresh_gate.dart';

void main() {
  group('Coalesced refresh gate', () {
    test('coalesces overlapping refreshes into one follow-up', () {
      final gate = CoalescedRefreshGate();
      expect(gate.begin(), isTrue);
      expect(gate.begin(), isFalse);
      expect(gate.begin(), isFalse);
      expect(gate.finish(), isTrue);
      expect(gate.finish(), isFalse);
      expect(gate.begin(), isTrue);
      expect(gate.finish(), isFalse);
    });

    test('does not create a phantom refresh after an idle finish', () {
      final gate = CoalescedRefreshGate();
      expect(gate.finish(), isFalse);
      expect(gate.begin(), isTrue);
      expect(gate.finish(), isFalse);
    });
  });
}
