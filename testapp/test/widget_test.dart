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

  group('Phone input hardening regression checks', () {
    final validInputs = <String>[
      '0700123456',
      '0700 123 456',
      '0700-123-456',
      '(0700) 123-456',
      '+996700123456',
      '+996 700 123 456',
      '+996 (700) 123-456',
      '996700123456',
      '0555123456',
      '+996555123456',
    ];
    for (final input in validInputs) {
      test('accepts formatted Kyrgyz number: $input', () {
        expect(FirebaseService.isValidKgPhone(input), isTrue);
      });
    }

    final invalidInputs = <String>[
      'abc0700123456',
      '0700abc123456',
      '07+00123456',
      '++996700123456',
      '996+700123456',
      '+996700123456abc',
      '0700/123/456',
      '0700.123.456',
      '0700_123_456',
      '070012345',
    ];
    for (final input in invalidInputs) {
      test('rejects malformed phone input: $input', () {
        expect(FirebaseService.isValidKgPhone(input), isFalse);
        expect(() => FirebaseService.phoneLoginEmail(input), throwsArgumentError);
      });
    }
  });

}
