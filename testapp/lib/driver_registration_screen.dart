import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import 'services/firebase_service.dart';
import 'services/worker_api.dart';
import 'services/driver_document_store.dart';
import 'services/taxi_localization.dart';

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

  String _cleanText(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  bool _hasControlCharacters(String value) =>
      value.codeUnits.any((unit) => unit < 32 || unit == 127);

  void _ensureActiveAccount(String uid) {
    final activeUid = FirebaseAuth.instance.currentUser?.uid;
    if (activeUid == null || activeUid != uid) {
      throw const WorkerApiException(
        'Аккаунт изменился во время отправки. Войдите снова и повторите попытку.',
      );
    }
  }

  void _setStage(String value) {
    if (mounted) setState(() => _stage = value);
  }

  void _message(String value) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: TaxiText(value), duration: const Duration(seconds: 5)),
    );
  }

  Future<void> _pick(String kind) async {
    if (_busy || !mounted) return;
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 78,
        maxWidth: 1400,
        maxHeight: 1400,
      );
      if (!mounted || file == null) return;
      final pickedSize = await file.length().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (pickedSize <= 0 || pickedSize > 8 * 1024 * 1024) {
        _message('Фото пустое или превышает 8 МБ. Выберите фотографию меньшего размера.');
        return;
      }
      final documentType = kind == 'driver' ? 'driver_photo' :
          kind == 'car' ? 'car_photo' : 'license';
      final retained = await DriverDocumentStore.persistPickedImage(
        uid: 'pending-registration', documentType: documentType, source: file,
      );
      if (!mounted) return;
      final localFile = XFile(retained.path);
      setState(() {
        if (kind == 'license') _license = localFile;
        if (kind == 'driver') _driverPhoto = localFile;
        if (kind == 'car') _carPhoto = localFile;
      });
    } on TimeoutException {
      _message('Фотография загружается слишком долго. Проверьте память телефона и повторите выбор.');
    } catch (_) {
      _message('Не удалось открыть фотографии. Проверьте разрешение на доступ к галерее.');
    }
  }

  Future<String> _upload(XFile file, String uid, String kind) async {
    _ensureActiveAccount(uid);
    const allowedKinds = {'license', 'driver_photo', 'car_photo'};
    if (!allowedKinds.contains(kind)) {
      throw const WorkerApiException('Неизвестный тип документа водителя.');
    }
    final expectedSize = await file.length().timeout(const Duration(seconds: 15));
    if (expectedSize <= 0 || expectedSize > 8 * 1024 * 1024) {
      throw const WorkerApiException('Фотография пустая или превышает 8 МБ. Выберите её заново.');
    }
    final bytes = await file.readAsBytes().timeout(const Duration(seconds: 30));
    if (bytes.isEmpty || bytes.length != expectedSize || bytes.length > 8 * 1024 * 1024) {
      throw const WorkerApiException('Фотография изменилась или превышает 8 МБ. Выберите её заново.');
    }
    final ref = FirebaseStorage.instanceFor(bucket: 'gs://jol-aman-kenchi.firebasestorage.app').ref().child('drivers/$uid/$kind.jpg');
    final task = await ref.putData(
      bytes,
      SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: {'ownerUid': uid, 'documentType': kind},
      ),
    ).timeout(const Duration(seconds: 90));
    _ensureActiveAccount(uid);
    final uploadedPath = task.ref.fullPath;
    if (uploadedPath != 'drivers/$uid/$kind.jpg') {
      throw const WorkerApiException('Хранилище вернуло неверный путь документа.');
    }
    return uploadedPath;
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
        _message('Фото ${i + 1} пустое или больше 8 МБ. Выберите фотографию меньшего размера.');
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

    // Once the route is popped successfully, do not call setState from
    // finally: the route is already leaving the widget tree.
    var registrationRoutePopped = false;
    try {
      if (!await _validatePhotoSizes()) return;
      if (!mounted) return;
      _setStage('Проверяем аккаунт…');
      final phone = _phone.text.trim();
      final password = _password.text;
      final driverName = _cleanText(_name.text);
      final carModel = _cleanText(_car.text);
      final carNumber = _cleanText(_plate.text).toUpperCase();
      if (password.trim().isEmpty) {
        throw const WorkerApiException('Пароль не должен состоять только из пробелов.');
      }

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
      _ensureActiveAccount(uid);

      _setStage('Сохраняем анкету водителя…');
      await WorkerApi.registerDriver(
        name: driverName,
        phone: phone,
        carModel: carModel,
        carNumber: carNumber,
      );
      if (!mounted) return;
      _ensureActiveAccount(uid);
      _setStage('Сохраняем оригиналы документов на телефоне…');
      final localLicense = await DriverDocumentStore.persistPickedImage(
        uid: uid, documentType: 'license', source: _license!,
      );
      final localDriverPhoto = await DriverDocumentStore.persistPickedImage(
        uid: uid, documentType: 'driver_photo', source: _driverPhoto!,
      );
      final localCarPhoto = await DriverDocumentStore.persistPickedImage(
        uid: uid, documentType: 'car_photo', source: _carPhoto!,
      );
      _license = XFile(localLicense.path);
      _driverPhoto = XFile(localDriverPhoto.path);
      _carPhoto = XFile(localCarPhoto.path);
      _ensureActiveAccount(uid);
      _setStage('Загружаем водительское удостоверение…');
      final licensePath = await _upload(_license!, uid, 'license');
      if (!mounted) return;
      _ensureActiveAccount(uid);
      _setStage('Загружаем фото водителя…');
      final driverPath = await _upload(_driverPhoto!, uid, 'driver_photo');
      if (!mounted) return;
      _ensureActiveAccount(uid);
      _setStage('Загружаем фото автомобиля…');
      final carPath = await _upload(_carPhoto!, uid, 'car_photo');
      if (!mounted) return;
      _ensureActiveAccount(uid);

      if (!mounted) return;
      _setStage('Отправляем документы диспетчеру…');
      await WorkerApi.saveDriverDocuments(
        licenseUrl: licensePath,
        driverPhotoUrl: driverPath,
        carPhotoUrl: carPath,
      );

      await FirebaseService.signOut().timeout(const Duration(seconds: 20));
      if (!mounted) return;
      registrationRoutePopped = true;
      Navigator.of(context).pop(true);
    } on TimeoutException {
      _message('Операция заняла слишком много времени. Проверьте интернет и повторите отправку.');
    } on FirebaseAuthException catch (e) {
      _message(_firebaseMessage(e));
    } on FirebaseException catch (e) {
      _message(e.code == 'unauthorized' || e.code == 'unauthenticated'
          ? 'Firebase не разрешил загрузку документов. Повторите вход и отправку.'
          : e.code == 'object-not-found'
              ? 'Firebase Storage не нашёл указанное хранилище. Проверьте, что в проекте jol-aman-kenchi создано хранилище jol-aman-kenchi.firebasestorage.app и опубликованы правила доступа.'
              : 'Ошибка хранилища фотографий (${e.code}) на этапе: ${_stage ?? 'загрузка'}. Проверьте интернет и повторите попытку.');
    } on WorkerApiException catch (e) {
      // Не удаляем созданный Firebase-аккаунт и не выходим из него:
      // следующая попытка сможет продолжить анкету на том же номере.
      _message('Не удалось завершить отправку анкеты: ${e.message}');
    } catch (_) {
      _message('Не удалось завершить регистрацию. Проверьте интернет и повторите попытку.');
    } finally {
      if (mounted && !registrationRoutePopped) {
        setState(() {
          _busy = false;
          _stage = null;
        });
      }
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

  Widget _photoTile(String title, XFile? file, String kind) {
    return Card(
      child: ListTile(
        leading: Icon(
          file == null ? Icons.add_a_photo_outlined : Icons.check_circle,
          color: file == null ? Colors.grey : Colors.green,
        ),
        title: TaxiText(title),
        subtitle: TaxiText(
          file == null ? 'Фотография не выбрана' : file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Tooltip(
          message: file == null ? 'Выбрать фотографию' : 'Заменить фотографию',
          child: TextButton(
            onPressed: _busy ? null : () => _pick(kind),
            child: TaxiText(file == null ? 'Выбрать' : 'Заменить'),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const TaxiText('Заявка водителя'),
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
              padding: EdgeInsets.fromLTRB(
                18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom,
              ),
              children: [
                const Icon(Icons.local_taxi, size: 58, color: Colors.amber),
                const TaxiText(
                  'Регистрация водителя «ЖОЛ АМАН КЕНЧИ»',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _name,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(labelText: 'ФИО водителя'),
                  maxLength: 80,
                  validator: (v) {
                    final value = _cleanText(v ?? '');
                    return _hasControlCharacters(value) || value.length < 3 || value.length > 80
                        ? 'Укажите ФИО без служебных символов (3–80 символов)'
                        : null;
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _phone,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  enableSuggestions: false,
                  autocorrect: false,
                  maxLength: 24,
                  decoration: const InputDecoration(labelText: 'Телефон 0XXXXXXXXX или +996XXXXXXXXX'),
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
                  obscureText: _obscurePassword,
                  enableSuggestions: false,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.next,
                  maxLength: 64,
                  decoration: InputDecoration(
                    labelText: 'Пароль (6–64 символа)',
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword ? 'Показать пароль' : 'Скрыть пароль',
                      onPressed: _busy
                          ? null
                          : () => setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                    ),
                  ),
                  validator: (v) => v == null || v.trim().isEmpty || v.length < 6
                      ? 'Минимум 6 символов, не только пробелы'
                      : v.length > 64 ? 'Не более 64 символов' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _car,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Марка и модель автомобиля'),
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.words,
                  autocorrect: false,
                  maxLength: 60,
                  validator: (v) {
                    final value = _cleanText(v ?? '');
                    return _hasControlCharacters(value) || value.length < 2
                        ? 'Укажите марку и модель без служебных символов'
                        : value.length > 60 ? 'Слишком длинное название автомобиля' : null;
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _plate,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Государственный номер'),
                  maxLength: 20,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  enableSuggestions: false,
                  validator: (v) {
                    final value = _cleanText(v ?? '');
                    return _hasControlCharacters(value) || value.length < 2
                        ? 'Укажите государственный номер без служебных символов'
                        : value.length > 20 ? 'Слишком длинный номер автомобиля' : null;
                  },
                ),
                const SizedBox(height: 18),
                const TaxiText('Фотографии для проверки диспетчером',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                _photoTile('Водительское удостоверение', _license, 'license'),
                _photoTile('Фото водителя', _driverPhoto, 'driver'),
                _photoTile('Фото автомобиля', _carPhoto, 'car'),
                const SizedBox(height: 8),
                const TaxiText(
                  'После отправки анкеты диспетчер проверит документы. До одобрения заявки вход в рабочий кабинет и приём заказов будут недоступны.',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 18),
                if (_busy) ...[
                  Semantics(
                    label: 'Идёт отправка анкеты водителя',
                    liveRegion: true,
                    child: LinearProgressIndicator(),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: TaxiText(_stage ?? 'Подождите…', textAlign: TextAlign.center),
                  ),
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
