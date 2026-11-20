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
      RegExp(r'[\\u0000-\\u001F\\u007F]').hasMatch(value);

  static String _validatedUid(String value) {
    final uid = value.trim();
    if (uid.isEmpty || uid.length > 128 || _hasControlCharacters(uid)) {
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
    if (normalized.isEmpty || normalized.length > 500 || _hasControlCharacters(normalized)) {
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

  static Future<Map<String, dynamic>> getTariffs() => _request('/tariffs');

  static Future<Map<String, dynamic>> saveTariffs({
    required int cityFareSom,
    required int intercityFareSom,
  }) {
    if (cityFareSom < 1 ||
        cityFareSom > 1000000 ||
        intercityFareSom < 1 ||
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
    final normalizedUid = uid.trim();
    final normalizedDecision = decision.trim().toLowerCase();
    final normalizedReason = reason.trim();
    if (normalizedUid.isEmpty || normalizedUid.length > 128) {
      throw const WorkerApiException('Не указан корректный UID водителя.');
    }
    if (!{'approved', 'rejected'}.contains(normalizedDecision)) {
      throw const WorkerApiException('Неизвестное решение по заявке водителя.');
    }
    if (normalizedReason.length > 500 || _hasControlCharacters(normalizedReason)) {
      throw const WorkerApiException('Причина решения слишком длинная.');
    }
    return _request('/drivers/review', method: 'POST', body: {
      'uid': normalizedUid,
      'decision': normalizedDecision,
      'reason': normalizedReason,
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
    final cleanPhone = phone.trim();
    final cleanCarModel = carModel.trim();
    final cleanCarNumber = carNumber.trim();
    if (cleanName.isEmpty || cleanName.length > 100 || _hasControlCharacters(cleanName) ||
        !RegExp(r'^(?:0\d{9}|\+996\d{9}|996\d{9})$').hasMatch(cleanPhone) ||
        cleanCarModel.isEmpty || cleanCarModel.length > 80 || _hasControlCharacters(cleanCarModel) ||
        cleanCarNumber.isEmpty || cleanCarNumber.length > 24 || _hasControlCharacters(cleanCarNumber)) {
      throw const WorkerApiException(
        'Проверьте имя, телефон, марку и номер автомобиля.',
      );
    }
    return _request('/drivers/register', method: 'POST', body: {
      'name': cleanName,
      'phone': cleanPhone,
      'car_model': cleanCarModel,
      'car_number': cleanCarNumber,
    });
  }

  static Future<Map<String, dynamic>> saveDriverDocuments({
    required String licenseUrl,
    required String driverPhotoUrl,
    required String carPhotoUrl,
  }) {
    final license = licenseUrl.trim();
    final driverPhoto = driverPhotoUrl.trim();
    final carPhoto = carPhotoUrl.trim();
    if ([license, driverPhoto, carPhoto].any((value) =>
        value.isEmpty || value.length > 2048 || _hasControlCharacters(value))) {
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
    if ((latitude == null) != (longitude == null)) {
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
    return _request('/orders/publish', method: 'POST', body: order);
  }

  static Future<Map<String, dynamic>> syncOrders(
    List<Map<String, dynamic>> orders,
  ) {
    if (orders.length > 500) {
      throw const WorkerApiException('Слишком много заказов для синхронизации.');
    }
    return _request('/orders/sync', method: 'POST', body: {'orders': orders});
  }

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
    if (id.isEmpty || id.length > 128 || _hasControlCharacters(id) || id.contains('/')) {
      throw const WorkerApiException('Не удалось выполнить действие: неверный номер заказа.');
    }
    return id;
  }

  static Future<Map<String, dynamic>> cancelOrder({
    required String orderId,
    required String role,
  }) {
    final normalizedRole = role.trim().toLowerCase();
    if (!{'customer', 'driver'}.contains(normalizedRole)) {
      throw const WorkerApiException('Недопустимая роль для отмены заказа.');
    }
    return _request('/orders/cancel', method: 'POST', body: {
      'order_id': _validatedOrderId(orderId),
      'role': normalizedRole,
    });
  }

  static Future<Map<String, dynamic>> markOrderArrived(String orderId) =>
      _request('/orders/arrived', method: 'POST', body: {
        'order_id': _validatedOrderId(orderId),
      });

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
