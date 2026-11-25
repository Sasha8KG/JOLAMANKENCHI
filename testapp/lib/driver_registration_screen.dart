import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'services/firebase_service.dart';
import 'services/worker_api.dart';
import 'services/taxi_localization.dart';

/// Регистрация водителя без обязательных фотографий и загрузки файлов.
class DriverRegistrationScreen extends StatefulWidget {
  const DriverRegistrationScreen({super.key});

  @override
  State<DriverRegistrationScreen> createState() => _DriverRegistrationScreenState();
}

class _DriverRegistrationScreenState extends State<DriverRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _car = TextEditingController();
  final _plate = TextEditingController();
  bool _busy = false;
  bool _obscurePassword = true;
  String? _stage;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    _car.dispose();
    _plate.dispose();
    super.dispose();
  }

  String _cleanText(String value) => value.trim().replaceAll(RegExp(r'\\s+'), ' ');
  bool _hasControlCharacters(String value) =>
      value.codeUnits.any((unit) => unit < 32 || unit == 127);

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: TaxiText(value), duration: const Duration(seconds: 5)));
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() { _busy = true; _stage = 'Проверяем аккаунт…'; });
    var routePopped = false;
    try {
      final phone = _phone.text.trim();
      final password = _password.text;
      final driverName = _cleanText(_name.text);
      final carModel = _cleanText(_car.text);
      final carNumber = _cleanText(_plate.text).toUpperCase();

      try {
        await FirebaseService.registerWithPhone(phone: phone, password: password);
      } on FirebaseAuthException catch (e) {
        if (e.code != 'email-already-in-use') rethrow;
        await FirebaseService.signInWithPhone(phone: phone, password: password);
      }

      if (!mounted) return;
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.uid.isEmpty) {
        throw const WorkerApiException('Firebase не вернул активный аккаунт. Повторите попытку.');
      }
      final uid = user.uid;
      setState(() => _stage = 'Сохраняем анкету водителя…');
      await WorkerApi.registerDriver(
        name: driverName,
        phone: phone,
        carModel: carModel,
        carNumber: carNumber,
      );
      if (!mounted) return;
      if (FirebaseAuth.instance.currentUser?.uid != uid) {
        throw const WorkerApiException('Аккаунт изменился во время регистрации. Войдите снова.');
      }
      setState(() => _stage = 'Завершаем регистрацию…');
      await FirebaseService.signOut().timeout(const Duration(seconds: 20));
      if (!mounted) return;
      routePopped = true;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      _message(_firebaseMessage(e));
    } on WorkerApiException catch (e) {
      _message('Не удалось завершить регистрацию: ${e.message}');
    } catch (e) {
      _message('Не удалось завершить регистрацию. Проверьте интернет и повторите попытку.');
    } finally {
      if (mounted && !routePopped) setState(() { _busy = false; _stage = null; });
    }
  }

  String _firebaseMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'Номер уже зарегистрирован. Проверьте пароль от этого аккаунта.';
      case 'weak-password':
        return 'Пароль должен содержать не менее 6 символов.';
      case 'network-request-failed':
        return 'Нет связи с Firebase. Проверьте интернет и повторите попытку.';
      case 'too-many-requests':
        return 'Слишком много попыток. Попробуйте позже.';
      case 'email-already-in-use':
        return 'Этот номер уже зарегистрирован. Войдите с ранее созданным паролем.';
      case 'invalid-email':
        return 'Не удалось подготовить номер телефона для входа. Проверьте его формат.';
      default:
        return 'Не удалось выполнить вход в Firebase. Проверьте данные и повторите попытку.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const TaxiText('Регистрация водителя'),
        backgroundColor: Colors.amber,
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: TaxiLanguageSwitcher())],
      ),
      body: Center(
        child: SafeArea(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: ListView(
                padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
                children: [
                  const Icon(Icons.local_taxi, size: 58, color: Colors.amber),
                  const TaxiText('Регистрация водителя «ЖОЛ АМАН КЕНЧИ»',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _name, enabled: !_busy,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.name],
                    decoration: const InputDecoration(labelText: 'ФИО водителя'),
                    maxLength: 80,
                    validator: (v) {
                      final value = _cleanText(v ?? '');
                      return _hasControlCharacters(value) || value.length < 3 || value.length > 80
                        ? 'Укажите ФИО (3–80 символов)' : null;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _phone, enabled: !_busy,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    enableSuggestions: false, autocorrect: false, maxLength: 24,
                    decoration: const InputDecoration(labelText: 'Телефон 0XXXXXXXXX или +996XXXXXXXXX'),
                    validator: (v) => FirebaseService.isValidKgPhone((v ?? '').trim())
                      ? null : 'Введите номер Кыргызстана: 0700123456 или +996700123456',
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _password, enabled: !_busy,
                    obscureText: _obscurePassword,
                    enableSuggestions: false, autocorrect: false,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.next, maxLength: 64,
                    decoration: InputDecoration(
                      labelText: 'Пароль (6–64 символа)',
                      suffixIcon: IconButton(
                        tooltip: _obscurePassword ? 'Показать пароль' : 'Скрыть пароль',
                        onPressed: _busy ? null : () => setState(() => _obscurePassword = !_obscurePassword),
                        icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                      ),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty || v.length < 6
                      ? 'Минимум 6 символов, не только пробелы'
                      : v.length > 64 ? 'Не более 64 символов' : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _car, enabled: !_busy,
                    decoration: const InputDecoration(labelText: 'Марка и модель автомобиля'),
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.words, autocorrect: false, maxLength: 60,
                    validator: (v) {
                      final value = _cleanText(v ?? '');
                      return _hasControlCharacters(value) || value.length < 2
                        ? 'Укажите марку и модель автомобиля'
                        : value.length > 60 ? 'Слишком длинное название автомобиля' : null;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _plate, enabled: !_busy,
                    decoration: const InputDecoration(labelText: 'Государственный номер'),
                    maxLength: 20, textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done, autocorrect: false, enableSuggestions: false,
                    validator: (v) {
                      final value = _cleanText(v ?? '');
                      return _hasControlCharacters(value) || value.length < 2
                        ? 'Укажите государственный номер'
                        : value.length > 20 ? 'Слишком длинный номер автомобиля' : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  const TaxiLocalizedText(
                    russian: 'Фотографии не требуются. После отправки анкеты диспетчер рассмотрит заявку и разрешит выход на линию.',
                    kyrgyz: 'Сүрөттөр талап кылынбайт. Анкета жөнөтүлгөндөн кийин диспетчер арызды карап чыгып, линияга чыгууга уруксат берет.',
                    style: TextStyle(color: Colors.black54, fontSize: 13),
                  ),
                  const SizedBox(height: 18),
                  if (_busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    TaxiText(_stage ?? 'Подождите…', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                  ],
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _submit,
                    icon: Icon(_busy ? Icons.hourglass_top : Icons.send),
                    label: TaxiText(_busy ? 'ОТПРАВКА…' : 'ОТПРАВИТЬ АНКЕТУ'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
