import 'package:flutter_test/flutter_test.dart';
import 'package:jolamankenchi_taxi/services/firebase_service.dart';

void main() {
  group('Кыргызский номер телефона', () {
    test('принимает локальный номер из десяти цифр', () {
      expect(FirebaseService.isValidKgPhone('0700123456'), isTrue);
      expect(
        FirebaseService.phoneLoginEmail('0700123456'),
        'kg996700123456@jolamankenchi.app',
      );
    });

    test('принимает международный номер с +996', () {
      expect(FirebaseService.isValidKgPhone('+996700123456'), isTrue);
      expect(
        FirebaseService.phoneLoginEmail('+996700123456'),
        'kg996700123456@jolamankenchi.app',
      );
    });

    test('принимает пробелы, дефисы и сбалансированные скобки', () {
      const formatted = '+996 (700) 123-456';
      expect(FirebaseService.isValidKgPhone(formatted), isTrue);
      expect(
        FirebaseService.phoneLoginEmail(formatted),
        'kg996700123456@jolamankenchi.app',
      );
      expect(FirebaseService.isValidKgPhone('0700 123-456'), isTrue);
    });

    test('локальный и международный варианты дают один логин', () {
      expect(
        FirebaseService.phoneLoginEmail('0700123456'),
        FirebaseService.phoneLoginEmail('+996700123456'),
      );
    });

    test('отклоняет неполные и лишние цифры', () {
      expect(FirebaseService.isValidKgPhone('700123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('070012345'), isFalse);
      expect(FirebaseService.isValidKgPhone('07001234567'), isFalse);
      expect(FirebaseService.isValidKgPhone('+99670012345'), isFalse);
    });

    test('отклоняет неправильные скобки и положение плюса', () {
      expect(FirebaseService.isValidKgPhone('+996 (700 123-456'), isFalse);
      expect(FirebaseService.isValidKgPhone('+996) 700 (123-456'), isFalse);
      expect(FirebaseService.isValidKgPhone('996+700123456'), isFalse);
      expect(FirebaseService.isValidKgPhone('++996700123456'), isFalse);
    });

    test('отклоняет буквы, добавочные номера и управляющие символы', () {
      expect(FirebaseService.isValidKgPhone('0700123456 доб. 12'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700ABC456'), isFalse);
      expect(FirebaseService.isValidKgPhone('0700123456\n'), isFalse);
      expect(FirebaseService.isValidKgPhone(''), isFalse);
    });
  });
}
