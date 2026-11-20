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
}
