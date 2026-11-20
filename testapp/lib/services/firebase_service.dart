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

  static bool isValidKgPhone(String phone) {
    final digits = phone.replaceAll('+', '').replaceAll(' ', '').replaceAll('-', '').replaceAll('(', '').replaceAll(')', '');
    return (digits.length == 10 && digits.startsWith('0')) ||
        (digits.length == 12 && digits.startsWith('996'));
  }
  static Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
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
        password: password,
      );

  static Future<UserCredential> register({
    required String email,
    required String password,
  }) {
    return auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
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
    await db.collection('appUsers').doc(uid).set({
      'uid': uid,
      'email': email.trim(),
      'role': role,
      'name': name.trim(),
      'phone': phone.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
).hasMatch(digits);
  }

  static Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
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
        password: password,
      );

  static Future<UserCredential> register({
    required String email,
    required String password,
  }) {
    return auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
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
    await db.collection('appUsers').doc(uid).set({
      'uid': uid,
      'email': email.trim(),
      'role': role,
      'name': name.trim(),
      'phone': phone.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
).hasMatch(digits);
  }

  static String phoneLoginEmail(String phone) {
    var digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0')) digits = '996${digits.substring(1)}';
    if (!digits.startsWith('996')) digits = '996$digits';
    return 'kg$digits@jolamankenchi.app';
  }

  static Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
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
        password: password,
      );

  static Future<UserCredential> register({
    required String email,
    required String password,
  }) {
    return auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
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
    await db.collection('appUsers').doc(uid).set({
      'uid': uid,
      'email': email.trim(),
      'role': role,
      'name': name.trim(),
      'phone': phone.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
