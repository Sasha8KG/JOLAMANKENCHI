import 'package:flutter_test/flutter_test.dart';
import 'package:sulyukta_taxi/services/firebase_service.dart';

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


  group('Kyrgyz phone normalization regression cases', () {
    final cases = <({String input, String expected})>[
      (input: '0700123456', expected: '+996700123456'),
      (input: '+996700123456', expected: '+996700123456'),
      (input: '996700123456', expected: '+996700123456'),
      (input: '+996 700 123 456', expected: '+996700123456'),
      (input: '+996 (700) 123-456', expected: '+996700123456'),
      (input: '0700 123 456', expected: '+996700123456'),
      (input: '0700-123-456', expected: '+996700123456'),
      (input: '(0700) 123-456', expected: '+996700123456'),
      (input: ' 0700123456 ', expected: '+996700123456'),
      (input: '+996-700-123-456', expected: '+996700123456'),
      (input: '0555123456', expected: '+996555123456'),
      (input: '+996555123456', expected: '+996555123456'),
      (input: '996555123456', expected: '+996555123456'),
      (input: '0777 000 111', expected: '+996777000111'),
      (input: '+996 (777) 000-111', expected: '+996777000111'),
      (input: '070012345', expected: ''),
      (input: '07001234567', expected: ''),
      (input: '+995700123456', expected: ''),
      (input: 'abc0700123456', expected: ''),
      (input: '07+00123456', expected: ''),
      (input: '++996700123456', expected: ''),
      (input: '', expected: ''),
    ];

    for (final item in cases) {
      test('normalizes "${item.input}"', () {
        expect(FirebaseService.normalizeKgPhone(item.input), item.expected);
        expect(FirebaseService.isValidKgPhone(item.input), item.expected.isNotEmpty);
      });
    }
  });

  group('Display name normalization', () {
    test('collapses repeated spaces', () {
      expect(FirebaseService.normalizeDisplayName('  Асан   Бек  '), 'Асан Бек');
    });

    test('collapses tabs and line breaks', () {
      expect(FirebaseService.normalizeDisplayName('Асан\\t\\nБек'), 'Асан Бек');
    });

    test('preserves single spaces between words', () {
      expect(FirebaseService.normalizeDisplayName('Aсан Бек уулу'), 'Aсан Бек уулу');
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
}
