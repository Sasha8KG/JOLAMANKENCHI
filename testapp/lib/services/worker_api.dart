import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';

/// API client for the existing Cloudflare Worker.
/// Every protected request is authorized with the current Firebase ID token.
class WorkerApi {
  WorkerApi._();

  static const String baseUrl =
      'https://jol-aman-kenchi-server.seshankulov2.workers.dev';
  static const Duration _timeout = Duration(seconds: 20);
  static const int _maxResponseBytes = 2 * 1024 * 1024;
  static const int _maxRequestBytes = 2 * 1024 * 1024;

  static bool _hasControlCharacters(String value) =>
      RegExp(r'[\x00-\x1F\x7F]').hasMatch(value);

  static bool _hasValidPhoneCharacters(String value) {
    final input = value.trim();
    if (input.isEmpty) return false;
    var digitCount = 0;
    var parenthesisDepth = 0;
    for (var i = 0; i < input.length; i++) {
      final unit = input.codeUnitAt(i);
      if (unit >= 48 && unit <= 57) {
        digitCount++;
      } else if (unit == 43) {
        if (i != 0) return false;
      } else if (unit == 32 || unit == 45) {
        // Spaces and hyphens are visual separators.
      } else if (unit == 40) {
        if (parenthesisDepth != 0) return false;
        parenthesisDepth = 1;
      } else if (unit == 41) {
        if (parenthesisDepth == 0) return false;
        parenthesisDepth = 0;
      } else {
        return false;
      }
    }
    return digitCount > 0 && parenthesisDepth == 0;
  }

  static String _normalizeKgPhone(String value) {
    final input = value.trim();
    if (!_hasValidPhoneCharacters(input)) return '';
    final digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10 && digits.startsWith('0')) return digits;
    if (digits.length == 12 && digits.startsWith('996')) {
      return input.startsWith('+') ? '+$digits' : digits;
    }
    return '';
  }

  static String _validatedUid(String value) {
    final uid = value.trim();
    if (uid.isEmpty || uid.length > 128 || uid.contains('/') || uid.contains('\\') || _hasControlCharacters(uid)) {
      throw const WorkerApiException('Не указан корректный UID пользователя.');
    }
    return uid;
  }

  static Future<String> _token() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const WorkerApiException('Сначала войдите в аккаунт Firebase.');
    }
    final token = await user.getIdToken().timeout(_timeout);
    final normalizedToken = token?.trim();
    if (normalizedToken == null || normalizedToken.isEmpty) {
      throw const WorkerApiException('Не удалось получить токен Firebase.');
    }
    return normalizedToken;
  }

  static Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    bool authenticated = true,
  }) async {
    final normalizedMethod = method.trim().toUpperCase();
    if (!['GET', 'POST'].contains(normalizedMethod)) {
      throw const WorkerApiException('Недопустимый тип запроса к серверу.');
    }
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('://') ||
        path.contains('#') ||
        path.contains('\\') ||
        RegExp(r'[\u0000-\u001F\u007F]').hasMatch(path)) {
      throw const WorkerApiException('Недопустимый адрес запроса к серверу.');
    }
    Uint8List? requestBytes;
    if (body != null) {
      try {
        requestBytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
      } catch (_) {
        throw const WorkerApiException(
          'Не удалось подготовить данные для отправки на сервер.',
        );
      }
    }
    if (requestBytes != null && requestBytes.length > _maxRequestBytes) {
      throw const WorkerApiException(
        'Отправляемые данные слишком большие. Уменьшите вложения и повторите попытку.',
      );
    }
    // Resolve authentication before opening a socket, so a slow token refresh
    // does not leave an unused HTTP connection waiting.
    final authToken = authenticated ? await _token() : null;
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final uri = Uri.parse('$baseUrl$path');
      if (uri.scheme != 'https' || uri.host != 'jol-aman-kenchi-server.seshankulov2.workers.dev' ||
          uri.userInfo.isNotEmpty || uri.port != 443) {
        throw const WorkerApiException('Неверный защищённый адрес сервера.');
      }
      final request = await client.openUrl(normalizedMethod, uri).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
      if (body != null) {
        request.headers.contentType = ContentType.json;
      }
      if (authenticated) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $authToken',
        );
      }
      // HttpClientRequest headers become immutable after the first body byte
      // is added. Set every header before writing the JSON payload.
      if (requestBytes != null) {
        request.contentLength = requestBytes.length;
        request.add(requestBytes);
      }
      final response = await request.close().timeout(_timeout);

      // Reject unexpectedly large responses before allocating memory.
      if (response.contentLength > _maxResponseBytes) {
        throw const WorkerApiException(
          'Ответ сервера слишком большой. Повторите попытку позже.',
        );
      }

      // Read with both an inactivity/overall timeout and a hard size limit.
      final responseBytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) {
          if (builder.length + chunk.length > _maxResponseBytes) {
            throw const WorkerApiException(
              'Ответ сервера слишком большой. Повторите попытку позже.',
            );
          }
          builder.add(chunk);
          return builder;
        },
      ).timeout(_timeout);

      final isSuccess = response.statusCode >= 200 && response.statusCode < 300;
      if (isSuccess && (response.statusCode == 204 || response.statusCode == 205)) {
        return <String, dynamic>{};
      }
      String responseText;
      try {
        responseText = utf8.decode(
          responseBytes.takeBytes(),
          allowMalformed: false,
        );
      } on FormatException {
        throw WorkerApiException(
          'Сервер передал данные в неверной кодировке (HTTP ${response.statusCode}).',
          statusCode: isSuccess ? null : response.statusCode,
        );
      }
      if (responseText.trim().isEmpty) {
        if (!isSuccess) {
          throw WorkerApiException(
            'Сервер вернул пустой ответ (HTTP ${response.statusCode}).',
            statusCode: response.statusCode,
          );
        }
        return <String, dynamic>{};
      }

      dynamic decoded;
      try {
        decoded = jsonDecode(responseText);
      } on FormatException {
        throw WorkerApiException(
          isSuccess
              ? 'Сервер вернул непонятный ответ (HTTP ${response.statusCode}).'
              : 'Сервер вернул некорректную ошибку (HTTP ${response.statusCode}).',
          statusCode: isSuccess ? null : response.statusCode,
        );
      }

      if (decoded == null) {
        throw WorkerApiException(
          'Сервер вернул пустые данные (HTTP ${response.statusCode}).',
          statusCode: isSuccess ? null : response.statusCode,
        );
      }
      final data = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{'data': decoded};
      if (!isSuccess) {
        throw WorkerApiException(
          ((data['message'] ?? data['error'] ??
                      'Ошибка сервера HTTP ${response.statusCode}')
                  .toString()
                  .trim())
              .substring(0, ((data['message'] ?? data['error'] ??
                          'Ошибка сервера HTTP ${response.statusCode}')
                      .toString()
                      .trim()
                      .length)
                  .clamp(0, 500)),
          statusCode: response.statusCode,
        );
      }
      return data;
    } on SocketException {
      throw const WorkerApiException(
        'Нет соединения с интернетом. Проверьте сеть и повторите попытку.',
      );
    } on HandshakeException {
      throw const WorkerApiException(
        'Не удалось установить защищённое соединение. Проверьте дату, время и интернет на телефоне.',
      );
    } on TimeoutException {
      throw const WorkerApiException(
        'Сервер долго не отвечает. Попробуйте ещё раз.',
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> radioMessages() => _request('/radio/messages');

  static Future<Map<String, dynamic>> sendRadioMessage(String message) {
    final normalized = message.trim();
    if (normalized.isEmpty || normalized.length > 500 || _hasControlCharacters(normalized) || normalized.contains('\n') || normalized.contains('\r')) {
      throw const WorkerApiException(
        'Сообщение должно содержать от 1 до 500 символов.',
      );
    }
    return _request('/radio/messages', method: 'POST', body: {
      'message': normalized,
    });
  }

  static Future<Map<String, dynamic>> radioToken() =>
      _request('/radio/token', method: 'POST', body: const {});

  static Future<Map<String, dynamic>> requestDriverDocuments(String driverUid) {
    final uid = driverUid.trim();
    if (uid.isEmpty || uid.length > 128 || _hasControlCharacters(uid)) {
      throw const WorkerApiException('Укажите корректный UID водителя.');
    }
    return _request('/drivers/documents/request', method: 'POST', body: {'uid': uid});
  }

  static Future<Map<String, dynamic>> driverDocumentRequest() =>
      _request('/drivers/documents/request');

  static Future<Map<String, dynamic>> driverDocumentsTransferToken(String requestId) {
    final id = requestId.trim();
    if (!RegExp(r'^[0-9a-f-]{36}$', caseSensitive: false).hasMatch(id)) {
      throw const WorkerApiException('Неверный номер запроса документов.');
    }
    return _request('/drivers/documents/token', method: 'POST', body: {'request_id': id});
  }

  static Future<Map<String, dynamic>> confirmDriverDocumentsReceived({
    required String requestId,
    required String driverUid,
    required List<Map<String, dynamic>> files,
  }) {
    final id = requestId.trim();
    final uid = driverUid.trim();
    const types = ['license', 'driver_photo', 'car_photo'];
    if (!RegExp(r'^[0-9a-f-]{36}$', caseSensitive: false).hasMatch(id) ||
        uid.isEmpty || uid.length > 128 || _hasControlCharacters(uid) ||
        files.length != 3) {
      throw const WorkerApiException('Не удалось проверить комплект документов.');
    }
    var total = 0;
    for (var i = 0; i < types.length; i++) {
      final file = files[i];
      final size = file['size'];
      final sha = (file['sha256'] ?? '').toString().toLowerCase();
      if (file['type'] != types[i] || size is! int || size < 1 ||
          size > 8 * 1024 * 1024 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
        throw const WorkerApiException('Сведения об одном из документов неверны.');
      }
      total += size;
    }
    if (total > 18 * 1024 * 1024) {
      throw const WorkerApiException('Общий размер документов превышает 18 МБ.');
    }
    return _request('/drivers/documents/received', method: 'POST', body: {
      'request_id': id, 'uid': uid, 'files': files,
    });
  }

  static Future<Map<String, dynamic>> radioFloor({required String action}) {
    final normalized = action.trim().toLowerCase();
    const allowedActions = {'status', 'acquire', 'refresh', 'release'};
    if (!allowedActions.contains(normalized)) {
      throw const WorkerApiException('Недопустимая команда голосовой рации.');
    }
    return _request(
      '/radio/ptt',
      method: normalized == 'status' ? 'GET' : 'POST',
      body: normalized == 'status' ? null : {'action': normalized},
    );
  }

  static Future<Map<String, dynamic>> health() =>
      _request('/health', authenticated: false);

  static Future<Map<String, dynamic>> checkAuth() =>
      _request('/auth/check', method: 'POST', body: const {});

  static Future<Map<String, dynamic>> driverProfile() =>
      _request('/drivers/me');

  static Future<Map<String, dynamic>> dispatcherOverview() =>
      _request('/dispatcher/overview');
  static Future<Map<String, dynamic>> dispatcherCancellations({
    int? beforeAt,
    String? beforeId,
  }) {
    final hasAt = beforeAt != null;
    final normalizedId = beforeId?.trim();
    if (hasAt != (normalizedId != null && normalizedId.isNotEmpty) ||
        (hasAt && (beforeAt < 0 || beforeAt > 9007199254740991 ||
            normalizedId!.length > 128 ||
            RegExp(r'[\x00-\x1F\x7F]').hasMatch(normalizedId)))) {
      throw const WorkerApiException('Некорректный указатель истории отмен.');
    }
    final query = hasAt
        ? '?before_at=$beforeAt&before_id=${Uri.encodeQueryComponent(normalizedId!)}'
        : '';
    return _request('/dispatcher/cancellations$query');
  }


  static Future<Map<String, dynamic>> getDriverEarnings() => _request('/driver/earnings');
  static Future<Map<String,dynamic>> registerDriverPushToken(String token) {
    final value=token.trim();
    if(value.length<20||value.length>4096||RegExp(r'[\\x00-\\x1F\\x7F]').hasMatch(value))
      throw const WorkerApiException('Некорректный токен уведомлений.');
    return _request('/drivers/push-token',method:'POST',body:{'token':value});
  }
  static Future<Map<String,dynamic>> closeOwnDriverShift() =>
      _request('/driver/shifts/close',method:'POST',body:const {});
  static Future<Map<String,dynamic>> returnDriverToLine() =>
      _request('/drivers/return-to-line',method:'POST',body:const {});

  static Future<Map<String, dynamic>> getTariffs() => _request('/tariffs');

  static Future<Map<String, dynamic>> saveTariffs({
    required int cityFareSom,
    required int intercityFareSom,
  }) {
    if (cityFareSom < 0 ||
        cityFareSom > 1000000 ||
        intercityFareSom < 0 ||
        intercityFareSom > 1000000) {
      throw const WorkerApiException(
        'Тариф должен быть от 1 до 1 000 000 сом.',
      );
    }
    return _request('/tariffs', method: 'POST', body: {
      'city_fare_som': cityFareSom,
      'intercity_fare_som': intercityFareSom,
    });
  }

  static Future<Map<String, dynamic>> setDriverCommission({
    required String driverUid,
    required int commissionPercent,
  }) {
    final uid = _validatedUid(driverUid);
    if (commissionPercent < 0 || commissionPercent > 100) {
      throw const WorkerApiException('Процент водителя должен быть от 0 до 100.');
    }
    return _request('/drivers/commission', method: 'POST', body: {
      'driver_uid': uid,
      'commission_percent': commissionPercent,
    });
  }

  static Future<Map<String,dynamic>> forceDriverOffline({required String driverUid}) {
    final uid=_validatedUid(driverUid);
    return _request('/dispatcher/drivers/force-offline',method:'POST',body:{'driver_uid':uid});
  }
  static Future<Map<String, dynamic>> closeDriverShift({
    required String driverUid,
    String? shiftDate,
  }) {
    final uid = _validatedUid(driverUid);
    final date = shiftDate?.trim();
    if (date != null) {
      final parsedDate = DateTime.tryParse(date);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) || parsedDate == null ||
          parsedDate.toIso8601String().substring(0, 10) != date) {
        throw const WorkerApiException('Укажите существующую дату смены в формате ГГГГ-ММ-ДД.');
      }
    }
    return _request('/dispatcher/shifts/close', method: 'POST', body: {
      'driver_uid': uid,
      if (date != null) 'shift_date': date,
    });
  }

  static Future<Map<String, dynamic>> approveDriver({
    required String uid,
    required bool approved,
  }) {
    final normalizedUid = _validatedUid(uid);
    return _request('/drivers/approve', method: 'POST', body: {
      'uid': normalizedUid,
      'approved': approved,
    });
  }

  static Future<Map<String, dynamic>> reviewDriver({
    required String uid,
    required String decision,
    String reason = '',
  }) {
    final normalizedUid = _validatedUid(uid);
    final normalizedDecision = decision.trim().toLowerCase();
    final normalizedReason = reason.trim();
    if (normalizedUid.isEmpty || normalizedUid.length > 128 || normalizedUid.contains('/') || normalizedUid.contains('\\') || _hasControlCharacters(normalizedUid)) {
      throw const WorkerApiException('Не указан корректный UID водителя.');
    }
    if (!{'approved', 'rejected'}.contains(normalizedDecision)) {
      throw const WorkerApiException('Неизвестное решение по заявке водителя.');
    }
    if (normalizedReason.length > 500 || _hasControlCharacters(normalizedReason) || normalizedReason.contains('\n') || normalizedReason.contains('\r') || (normalizedDecision == 'rejected' && normalizedReason.length < 5)) {
      throw const WorkerApiException('Для отказа укажите причину от 5 до 500 символов.');
    }
    return _request('/drivers/review', method: 'POST', body: {
      'uid': normalizedUid,
      'decision': normalizedDecision,
      'reason': normalizedReason,
    });
  }

  static Future<Map<String, dynamic>> removeOpenOrder({
    required String orderId,
  }) {
    return _request('/dispatcher/orders/remove', method: 'POST', body: {
      'order_id': _validatedOrderId(orderId),
    });
  }

  static Future<Map<String, dynamic>> assignOrder({
    required String orderId,
    required String driverUid,
  }) {
    final uid = _validatedUid(driverUid);
    return _request('/orders/assign', method: 'POST', body: {
      'order_id': _validatedOrderId(orderId),
      'driver_uid': uid,
    });
  }

  static Future<Map<String, dynamic>> registerDriver({
    required String name,
    required String phone,
    required String carModel,
    required String carNumber,
  }) {
    final cleanName = name.trim();
    final cleanPhone = _normalizeKgPhone(phone);
    final cleanCarModel = carModel.trim();
    final cleanCarNumber = carNumber.trim();
    final validPhone = cleanPhone.isNotEmpty;
    if (cleanName.length < 2 || cleanName.length > 80 || _hasControlCharacters(cleanName) ||
        !validPhone ||
        cleanCarModel.length < 2 || cleanCarModel.length > 60 || _hasControlCharacters(cleanCarModel) ||
        cleanCarNumber.length < 2 || cleanCarNumber.length > 20 || _hasControlCharacters(cleanCarNumber)) {
      throw const WorkerApiException(
        'Проверьте ФИО (2–80 символов), телефон, марку (2–60) и номер автомобиля (2–20).',
      );
    }
    return _request('/drivers/register', method: 'POST', body: {
      'name': cleanName,
      'phone': cleanPhone,
      'car_model': cleanCarModel,
      'car_number': cleanCarNumber,
    });
  }

  static Future<Map<String, dynamic>> resubmitDriverDocuments() {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty || uid.length > 128 || _hasControlCharacters(uid)) {
      throw const WorkerApiException('Не удалось определить аккаунт водителя.');
    }
    return _request('/drivers/documents/resubmit', method: 'POST', body: const {});
  }

  static Future<Map<String, dynamic>> saveDriverDocuments({
    required String licenseUrl,
    required String driverPhotoUrl,
    required String carPhotoUrl,
  }) {
    final license = licenseUrl.trim();
    final driverPhoto = driverPhotoUrl.trim();
    final carPhoto = carPhotoUrl.trim();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty ||
        license != 'drivers/$uid/license.jpg' ||
        driverPhoto != 'drivers/$uid/driver_photo.jpg' ||
        carPhoto != 'drivers/$uid/car_photo.jpg' ||
        {license, driverPhoto, carPhoto}.length != 3 ||
        [license, driverPhoto, carPhoto].any((value) =>
            value.length > 500 || _hasControlCharacters(value) ||
            value.contains('..') || value.contains('?') ||
            value.contains('#') || value.contains('\\'))) {
      throw const WorkerApiException('Не все документы водителя подготовлены корректно.');
    }
    return _request('/drivers/documents', method: 'POST', body: {
      'license_url': license,
      'driver_photo_url': driverPhoto,
      'car_photo_url': carPhoto,
    });
  }

  static Future<Map<String, dynamic>> setDriverOnline({
    required bool online,
    double? latitude,
    double? longitude,
  }) {
    if ((latitude == null) != (longitude == null) || (online && latitude == null)) {
      throw const WorkerApiException('Для GPS нужны обе координаты.');
    }
    if (latitude != null && longitude != null &&
        (!latitude.isFinite ||
            !longitude.isFinite ||
            latitude < -90 ||
            latitude > 90 ||
            longitude < -180 ||
            longitude > 180)) {
      throw const WorkerApiException('Получены неверные координаты GPS.');
    }
    return _request('/drivers/online', method: 'POST', body: {
      'online': online,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
    });
  }

  static Future<Map<String, dynamic>> publishOrder(
    Map<String, dynamic> order,
  ) {
    if (order.isEmpty) {
      throw const WorkerApiException('В заказе отсутствуют данные.');
    }
    final orderId = _validatedOrderId((order['id'] ?? '').toString());
    final pickup = (order['pickup'] ?? '').toString().trim();
    if (pickup.isEmpty || pickup.length > 200 || _hasControlCharacters(pickup)) {
      throw const WorkerApiException('Укажите корректное место подачи автомобиля.');
    }
    final destination = (order['destination'] ?? '').toString().trim();
    if (destination.isEmpty || destination.length > 200 ||
        _hasControlCharacters(destination)) {
      throw const WorkerApiException('Укажите корректный пункт назначения.');
    }
    final latitude = order['pickupLat'];
    final longitude = order['pickupLng'];
    if (latitude is! num || longitude is! num ||
        !latitude.toDouble().isFinite || !longitude.toDouble().isFinite ||
        latitude < -90 || latitude > 90 ||
        longitude < -180 || longitude > 180) {
      throw const WorkerApiException('Проверьте координаты места подачи автомобиля.');
    }
    final normalizedOrder = Map<String, dynamic>.from(order)
      ..['id'] = orderId
      ..['pickup'] = pickup
      ..['destination'] = destination;
    return _request('/orders/publish', method: 'POST', body: normalizedOrder);
  }

  static Future<Map<String, dynamic>> syncOrders(
    List<Map<String, dynamic>> orders,
  ) {
    final ids = orders.map((order) => _validatedOrderId((order['id'] ?? '').toString())).toList();
    if (ids.toSet().length != ids.length) {
      throw const WorkerApiException('Список заказов содержит пустые или повторяющиеся номера.');
    }
    if (orders.isEmpty || orders.length > 500 || orders.any((order) => order.isEmpty)) {
      throw const WorkerApiException('Список заказов для синхронизации пуст или содержит слишком много записей.');
    }
    return _request('/orders/sync', method: 'POST', body: {'orders': orders});
  }

  static Future<Map<String, dynamic>> nearbyDrivers() =>
      _request('/drivers/nearby');

  static Future<Map<String, dynamic>> openOrders() => _request('/orders/open');

  static Future<Map<String, dynamic>> orderStatus(String orderId) {
    final id = _validatedOrderId(orderId);
    return _request('/orders/status?id=${Uri.encodeQueryComponent(id)}');
  }

  static Future<Map<String, dynamic>> respondToOrder(String orderId) =>
      _request('/orders/respond', method: 'POST', body: {
        'order_id': _validatedOrderId(orderId),
      });

  static String _validatedOrderId(String orderId) {
    final id = orderId.trim();
    if (id.isEmpty || id.length > 128 || _hasControlCharacters(id) || id.contains('/') || id.contains('\\') || id.contains('#') || id.contains('?')) {
      throw const WorkerApiException('Не удалось выполнить действие: неверный номер заказа.');
    }
    return id;
  }

  static Future<Map<String, dynamic>> cancelOrder({
    required String orderId,
    required String role,
    String? reason,
  }) {
    final normalizedRole = role.trim().toLowerCase();
    if (!{'customer', 'driver'}.contains(normalizedRole)) {
      throw const WorkerApiException('Недопустимая роль для отмены заказа.');
    }
    const allowedReasons = {
      'customer_not_found',
      'customer_unreachable',
      'customer_left_with_other_car',
    };
    if (reason != null && (normalizedRole != 'driver' || !allowedReasons.contains(reason))) {
      throw const WorkerApiException('Недопустимая причина отмены заказа.');
    }
    return _request('/orders/cancel', method: 'POST', body: {
      'order_id': _validatedOrderId(orderId),
      'role': normalizedRole,
      if (reason != null) 'reason': reason,
    });
  }

  static Future<Map<String, dynamic>> markOrderArrived(String orderId) =>
      _request('/orders/arrived', method: 'POST', body: {
        'order_id': _validatedOrderId(orderId),
      });

  static Future<Map<String, dynamic>> completeDriverOrder({
    required String orderId,
    required int fareSom,
  }) {
    if (fareSom < 1 || fareSom > 1000000) {
      throw const WorkerApiException('Стоимость поездки должна быть от 1 до 1 000 000 сом.');
    }
    return _request('/orders/complete-driver', method: 'POST', body: {
      'order_id': _validatedOrderId(orderId),
      'fare_som': fareSom,
    });
  }

  static Future<Map<String, dynamic>> completeOrder({
    required String orderId,
    required int fareSom,
  }) {
    if (fareSom < 1 || fareSom > 1000000) {
      throw const WorkerApiException('Стоимость поездки должна быть от 1 до 1 000 000 сом.');
    }
    return _request('/orders/complete', method: 'POST', body: {
      'order_id': _validatedOrderId(orderId),
      'fare_som': fareSom,
    });
  }
}


class WorkerApiException implements Exception {
  final String message;
  final int? statusCode;

  const WorkerApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
