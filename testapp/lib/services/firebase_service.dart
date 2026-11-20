import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Firebase access for «ЖОЛ АМАН КЕНЧИ» такси.
/// Phone numbers are mapped to a private email-shaped login because the
/// existing Firebase project uses Email/Password authentication.
class FirebaseService {
  FirebaseService._();

  static final FirebaseAuth auth = FirebaseAuth.instance;
  static final FirebaseFirestore db = FirebaseFirestore.instance;

  static Stream<User?> get authStateChanges => auth.authStateChanges();

  static String _phoneDigits(String phone) {
    final digits = phone.trim().replaceAll(RegExp(r'\\D'), '');
    if (digits.length == 10 && digits.startsWith('0')) return digits;
    if (digits.length == 12 && digits.startsWith('996')) return digits;
    return '';
  }

  static String _normalizeWhitespace(String value) =>
      value.trim().replaceAll(RegExp(r'\\s+'), ' ');

  static String _validatedUid(String uid) {
    final value = uid.trim();
    if (value.isEmpty ||
        value.length > 128 ||
        value.contains('/') ||
        value.contains('\\\\') ||
        RegExp(r'[\\x00-\\x1F\\x7F]').hasMatch(value)) {
      throw ArgumentError.value(uid, 'uid', 'Некорректный UID пользователя.');
    }
    return value;
  }

  static String _validatedPassword(String password) {
    if (password.isEmpty || password.length > 4096) {
      throw ArgumentError.value(password, 'password', 'Введите корректный пароль.');
    }
    return password;
  }

  static String _validatedEmail(String email) {
    final value = email.trim();
    if (value.isEmpty ||
        value.length > 254 ||
        RegExp(r'[\\s\\x00-\\x1F\\x7F]').hasMatch(value) ||
        !value.contains('@')) {
      throw ArgumentError.value(email, 'email', 'Введите корректный адрес электронной почты.');
    }
    return value;
  }

  /// Accepts Kyrgyz numbers in local (0700123456) or international
  /// (+996700123456) form. Spaces, brackets and hyphens are ignored.
  static bool isValidKgPhone(String phone) => _phoneDigits(phone).isNotEmpty;

  static String phoneLoginEmail(String phone) {
    final digits = _phoneDigits(phone);
    if (digits.isEmpty) {
      throw ArgumentError.value(
        phone,
        'phone',
        'Введите номер Кыргызстана, например 0700123456.',
      );
    }
    final international = digits.startsWith('0')
        ? '996${digits.substring(1)}'
        : digits;
    return 'kg${international}@jolamankenchi.app';
  }

  static Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return auth.signInWithEmailAndPassword(
      email: _validatedEmail(email),
      password: _validatedPassword(password),
    );
  }

  static Future<UserCredential> signInWithPhone({
    required String phone,
    required String password,
  }) =>
      signIn(email: phoneLoginEmail(phone), password: password);

  static Future<UserCredential> registerWithPhone({
    required String phone,
    required String password,
  }) =>
      auth.createUserWithEmailAndPassword(
        email: phoneLoginEmail(phone),
        password: _validatedPassword(password),
      );

  static Future<UserCredential> register({
    required String email,
    required String password,
  }) {
    return auth.createUserWithEmailAndPassword(
      email: _validatedEmail(email),
      password: _validatedPassword(password),
    );
  }

  static Future<void> signOut() => auth.signOut();

  static Future<void> saveUserProfile({
    required String uid,
    required String email,
    required String role,
    required String name,
    String phone = '',
  }) async {
    final normalizedUid = _validatedUid(uid);
    final normalizedEmail = _validatedEmail(email);
    final normalizedRole = role.trim().toLowerCase();
    final normalizedName = _normalizeWhitespace(name);
    final normalizedPhone = phone.trim();

    if (normalizedRole.isEmpty ||
        normalizedRole.length > 32 ||
        RegExp(r'[\\x00-\\x1F\\x7F]').hasMatch(normalizedRole)) {
      throw ArgumentError.value(role, 'role', 'Некорректная роль пользователя.');
    }
    if (normalizedName.isEmpty ||
        normalizedName.length > 80 ||
        RegExp(r'[\\x00-\\x1F\\x7F]').hasMatch(normalizedName)) {
      throw ArgumentError.value(name, 'name', 'Проверьте имя пользователя.');
    }
    if (normalizedPhone.isNotEmpty && !isValidKgPhone(normalizedPhone)) {
      throw ArgumentError.value(
        phone,
        'phone',
        'Введите номер Кыргызстана, например 0700123456.',
      );
    }

    await db.collection('appUsers').doc(normalizedUid).set({
      'uid': normalizedUid,
      'email': normalizedEmail,
      'role': normalizedRole,
      'name': normalizedName,
      'phone': normalizedPhone,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
