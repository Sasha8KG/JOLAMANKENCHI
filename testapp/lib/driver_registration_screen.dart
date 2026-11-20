import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import 'services/firebase_service.dart';
import 'services/worker_api.dart';

/// Отдельный экран регистрации водителя. Не использует вложенный StatefulBuilder
/// и диалог с Form GlobalKey, чтобы форма не уничтожалась во время загрузки фото.
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
  final _picker = ImagePicker();

  XFile? _license;
  XFile? _driverPhoto;
  XFile? _carPhoto;
  bool _busy = false;
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

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value), duration: const Duration(seconds: 5)),
    );
  }

  Future<void> _pick(String kind) async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 78,
        maxWidth: 1400,
      );
      if (!mounted || file == null) return;
      setState(() {
        if (kind == 'license') _license = file;
        if (kind == 'driver') _driverPhoto = file;
        if (kind == 'car') _carPhoto = file;
      });
    } catch (e) {
      _message('Не удалось открыть фотографии: $e');
    }
  }

  Future<String> _upload(XFile file, String uid, String kind) async {
    final ref = FirebaseStorage.instance.ref().child('drivers/$uid/$kind.jpg');
    final task = await ref.putData(
      await file.readAsBytes(),
      SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: {'ownerUid': uid},
      ),
    );
    return task.ref.fullPath;
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    if (_license == null || _driverPhoto == null || _carPhoto == null) {
      _message('Добавьте фото водительского удостоверения, водителя и автомобиля.');
      return;
    }

    setState(() {
      _busy = true;
      _stage = 'Проверяем аккаунт…';
    });

    try {
      final phone = _phone.text.trim();
      final password = _password.text;

      // Если прошлый запуск успел создать Firebase-аккаунт, но не завершил
      // анкету, повторный запуск войдёт в него и продолжит регистрацию.
      try {
        await FirebaseService.registerWithPhone(phone: phone, password: password);
      } on FirebaseAuthException catch (e) {
        if (e.code != 'email-already-in-use') rethrow;
        await FirebaseService.signInWithPhone(phone: phone, password: password);
      }

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw const WorkerApiException('Firebase не вернул активный аккаунт. Повторите попытку.');
      }
      final uid = user.uid;

      setState(() => _stage = 'Сохраняем анкету водителя…');
      await WorkerApi.registerDriver(
        name: _name.text,
        phone: phone,
        carModel: _car.text,
        carNumber: _plate.text,
      );

      setState(() => _stage = 'Загружаем документы и фотографии…');
      final licensePath = await _upload(_license!, uid, 'license');
      final driverPath = await _upload(_driverPhoto!, uid, 'driver_photo');
      final carPath = await _upload(_carPhoto!, uid, 'car_photo');

      setState(() => _stage = 'Отправляем документы диспетчеру…');
      await WorkerApi.saveDriverDocuments(
        licenseUrl: licensePath,
        driverPhotoUrl: driverPath,
        carPhotoUrl: carPath,
      );

      await FirebaseService.signOut();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      _message(_firebaseMessage(e));
    } on WorkerApiException catch (e) {
      // Не удаляем созданный Firebase-аккаунт и не выходим из него:
      // следующая попытка сможет продолжить анкету на том же номере.
      _message('Не удалось завершить отправку анкеты: ${e.message}');
    } catch (e) {
      _message('Ошибка регистрации: $e');
    } finally {
      if (mounted) setState(() {
        _busy = false;
        _stage = null;
      });
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
      default:
        return 'Ошибка Firebase: ${e.message ?? e.code}';
    }
  }

  Widget _photoTile(String title, XFile? file, String kind) {
    return Card(
      child: ListTile(
        leading: Icon(
          file == null ? Icons.add_a_photo_outlined : Icons.check_circle,
          color: file == null ? Colors.grey : Colors.green,
        ),
        title: Text(title),
        subtitle: Text(file == null ? 'Фотография не выбрана' : 'Фотография выбрана'),
        trailing: TextButton(
          onPressed: _busy ? null : () => _pick(kind),
          child: Text(file == null ? 'Выбрать' : 'Заменить'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Заявка водителя'),
        backgroundColor: Colors.amber,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                const Icon(Icons.local_taxi, size: 58, color: Colors.amber),
                const Text(
                  'Регистрация водителя «ЖОЛ АМАН КЕНЧИ»',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _name,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'ФИО водителя'),
                  validator: (v) => v == null || v.trim().isEmpty ? 'Укажите ФИО' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _phone,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Телефон 0XXXXXXXXX'),
                  validator: (v) {
                    final digits = (v ?? '').replaceAll(RegExp(r'\\D'), '');
                    return RegExp(r'^0\\d{9}$').hasMatch(digits)
                        ? null
                        : 'Введите номер Кыргызстана, например 0700123456';
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Пароль (минимум 6 символов)'),
                  validator: (v) => v == null || v.length < 6 ? 'Минимум 6 символов' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _car,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Марка и модель автомобиля'),
                  validator: (v) => v == null || v.trim().isEmpty ? 'Укажите автомобиль' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _plate,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Государственный номер'),
                  validator: (v) => v == null || v.trim().isEmpty ? 'Укажите номер автомобиля' : null,
                ),
                const SizedBox(height: 18),
                const Text('Фотографии для проверки диспетчером',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                _photoTile('Водительское удостоверение', _license, 'license'),
                _photoTile('Фото водителя', _driverPhoto, 'driver'),
                _photoTile('Фото автомобиля', _carPhoto, 'car'),
                const SizedBox(height: 8),
                const Text(
                  'После отправки анкеты диспетчер проверит документы. До одобрения заявки вход в рабочий кабинет и приём заказов будут недоступны.',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 18),
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_stage ?? 'Подождите…', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                ],
                ElevatedButton.icon(
                  onPressed: _busy ? null : _submit,
                  icon: const Icon(Icons.send),
                  label: Text(_busy ? 'ОТПРАВКА…' : 'ОТПРАВИТЬ АНКЕТУ'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
