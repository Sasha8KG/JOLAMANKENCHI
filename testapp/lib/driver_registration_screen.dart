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

  void _setStage(String value) {
    if (mounted) setState(() => _stage = value);
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value), duration: const Duration(seconds: 5)),
    );
  }

  Future<void> _pick(String kind) async {
    if (_busy || !mounted) return;
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
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const WorkerApiException('Фотография изменилась или превышает 8 МБ. Выберите её заново.');
    }
    final ref = FirebaseStorage.instance.ref().child('drivers/$uid/$kind.jpg');
    final task = await ref.putData(
      bytes,
      SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: {'ownerUid': uid},
      ),
    ).timeout(const Duration(seconds: 90));
    return task.ref.fullPath;
  }

  Future<bool> _validatePhotoSizes() async {
    const maxPhotoBytes = 8 * 1024 * 1024;
    const maxTotalBytes = 18 * 1024 * 1024;
    final files = [_license!, _driverPhoto!, _carPhoto!];
    var totalBytes = 0;
    for (var i = 0; i < files.length; i++) {
      final size = await files[i].length().timeout(const Duration(seconds: 15));
      if (!mounted) return false;
      if (size <= 0 || size > maxPhotoBytes) {
        _message('Фото ' + (i + 1).toString() + ' пустое или больше 8 МБ. Выберите фотографию меньшего размера.');
        return false;
      }
      totalBytes += size;
    }
    if (totalBytes > maxTotalBytes) {
      _message('Общий размер трёх фотографий превышает 18 МБ. Уменьшите фотографии.');
      return false;
    }
    return true;
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    if (_license == null || _driverPhoto == null || _carPhoto == null) {
      _message('Добавьте фото водительского удостоверения, водителя и автомобиля.');
      return;
    }

    // Блокируем повторное нажатие уже на время предварительной проверки файлов.
    setState(() {
      _busy = true;
      _stage = 'Проверяем размер фотографий…';
    });

    try {
      if (!await _validatePhotoSizes()) return;
      if (!mounted) return;
      _setStage('Проверяем аккаунт…');
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

      if (!mounted) return;
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw const WorkerApiException('Firebase не вернул активный аккаунт. Повторите попытку.');
      }
      final uid = user.uid;

      _setStage('Сохраняем анкету водителя…');
      await WorkerApi.registerDriver(
        name: _name.text.trim(),
        phone: phone,
        carModel: _car.text.trim(),
        carNumber: _plate.text.trim(),
      );
      if (!mounted) return;
      _setStage('Загружаем водительское удостоверение…');
      final licensePath = await _upload(_license!, uid, 'license');
      if (!mounted) return;
      _setStage('Загружаем фото водителя…');
      final driverPath = await _upload(_driverPhoto!, uid, 'driver_photo');
      if (!mounted) return;
      _setStage('Загружаем фото автомобиля…');
      final carPath = await _upload(_carPhoto!, uid, 'car_photo');

      if (!mounted) return;
      _setStage('Отправляем документы диспетчеру…');
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
    } on FirebaseException catch (e) {
      _message(e.code == 'unauthorized' || e.code == 'unauthenticated'
          ? 'Firebase не разрешил загрузку документов. Повторите вход и отправку.'
          : 'Ошибка хранилища фотографий (${e.code}). Проверьте интернет и повторите попытку.');
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
                  maxLength: 80,
                  validator: (v) => v == null || v.trim().length < 2 ||
                          v.trim().length > 80
                      ? 'Укажите ФИО (от 2 до 80 символов)'
                      : v.trim().length > 80 ? 'Слишком длинное ФИО' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _phone,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Телефон 0XXXXXXXXX'),
                  validator: (v) {
                    return FirebaseService.isValidKgPhone((v ?? '').trim())
                        ? null
                        : 'Введите номер Кыргызстана: 0700123456 или +996700123456';
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  maxLength: 64,
                  decoration: const InputDecoration(labelText: 'Пароль (6–64 символа)'),
                  validator: (v) => v == null || v.length < 6
                      ? 'Минимум 6 символов'
                      : v.length > 64 ? 'Не более 64 символов' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _car,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Марка и модель автомобиля'),
                  maxLength: 60,
                  validator: (v) => v == null || v.trim().length < 2
                      ? 'Укажите марку и модель автомобиля'
                      : v.trim().length > 60 ? 'Слишком длинное название автомобиля' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _plate,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Государственный номер'),
                  maxLength: 20,
                  validator: (v) => v == null || v.trim().length < 2
                      ? 'Укажите государственный номер автомобиля'
                      : v.trim().length > 20 ? 'Слишком длинный номер автомобиля' : null,
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
