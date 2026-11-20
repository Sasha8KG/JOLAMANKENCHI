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

  static Future<String> _token() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const WorkerApiException('Сначала войдите в аккаунт Firebase.');
    }
    final token = await user.getIdToken().timeout(_timeout);
    if (token == null || token.isEmpty) {
      throw const WorkerApiException('Не удалось получить токен Firebase.');
    }
    return token;
  }

  static Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    bool authenticated = true,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final uri = Uri.parse('$baseUrl$path');
      final request = await client.openUrl(method, uri).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
      }
      if (authenticated) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${await _token()}',
        );
      }
      // HttpClientRequest headers become immutable after the first body byte
      // is added. Set every header before writing the JSON payload.
      if (body != null) {
        final requestBytes = utf8.encode(jsonEncode(body));
        if (requestBytes.length > _maxRequestBytes) {
          throw const WorkerApiException(
            'Отправляемые данные слишком большие. Уменьшите вложения и повторите попытку.',
          );
        }
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

      final data = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{'data': decoded};
      if (!isSuccess) {
        throw WorkerApiException(
          (data['message'] ?? data['error'] ??
                  'Ошибка сервера HTTP ${response.statusCode}')
              .toString(),
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

  static Future<Map<String, dynamic>> sendRadioMessage(String message) =>
      _request('/radio/messages', method: 'POST', body: {'message': message});

  static Future<Map<String, dynamic>> radioToken() =>
      _request('/radio/token', method: 'POST', body: const {});

  static Future<Map<String, dynamic>> radioFloor({required String action}) =>
      _request('/radio/ptt', method: action == 'status' ? 'GET' : 'POST',
        body: action == 'status' ? null : {'action': action});

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
  }) => _request('/tariffs', method: 'POST', body: {
    'city_fare_som': cityFareSom,
    'intercity_fare_som': intercityFareSom,
  });

  static Future<Map<String, dynamic>> setDriverCommission({
    required String driverUid,
    required int commissionPercent,
  }) => _request('/drivers/commission', method: 'POST', body: {
    'driver_uid': driverUid,
    'commission_percent': commissionPercent,
  });

  static Future<Map<String, dynamic>> closeDriverShift({
    required String driverUid,
    String? shiftDate,
  }) => _request('/dispatcher/shifts/close', method: 'POST', body: {
    'driver_uid': driverUid,
    if (shiftDate != null) 'shift_date': shiftDate,
  });

  static Future<Map<String, dynamic>> approveDriver({
    required String uid,
    required bool approved,
  }) =>
      _request('/drivers/approve', method: 'POST', body: {
        'uid': uid,
        'approved': approved,
      });

  static Future<Map<String, dynamic>> reviewDriver({
    required String uid,
    required String decision,
    String reason = '',
  }) => _request('/drivers/review', method: 'POST', body: {
    'uid': uid,
    'decision': decision,
    'reason': reason,
  });

  static Future<Map<String, dynamic>> assignOrder({
    required String orderId,
    required String driverUid,
  }) =>
      _request('/orders/assign', method: 'POST', body: {
        'order_id': orderId,
        'driver_uid': driverUid,
      });

  static Future<Map<String, dynamic>> registerDriver({
    required String name,
    required String phone,
    required String carModel,
    required String carNumber,
  }) =>
      _request('/drivers/register', method: 'POST', body: {
        'name': name.trim(),
        'phone': phone.trim(),
        'car_model': carModel.trim(),
        'car_number': carNumber.trim(),
      });

  static Future<Map<String, dynamic>> saveDriverDocuments({
    required String licenseUrl,
    required String driverPhotoUrl,
    required String carPhotoUrl,
  }) => _request('/drivers/documents', method: 'POST', body: {
    'license_url': licenseUrl,
    'driver_photo_url': driverPhotoUrl,
    'car_photo_url': carPhotoUrl,
  });

  static Future<Map<String, dynamic>> setDriverOnline({
    required bool online,
    double? latitude,
    double? longitude,
  }) =>
      _request('/drivers/online', method: 'POST', body: {
        'online': online,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      });

  static Future<Map<String, dynamic>> publishOrder(
    Map<String, dynamic> order,
  ) =>
      _request('/orders/publish', method: 'POST', body: order);

  static Future<Map<String, dynamic>> syncOrders(
    List<Map<String, dynamic>> orders,
  ) =>
      _request('/orders/sync', method: 'POST', body: {'orders': orders});

  static Future<Map<String, dynamic>> openOrders() => _request('/orders/open');

  static Future<Map<String, dynamic>> orderStatus(String orderId) =>
      _request('/orders/status?id=${Uri.encodeQueryComponent(orderId)}');

  static Future<Map<String, dynamic>> respondToOrder(String orderId) =>
      _request('/orders/respond',
          method: 'POST', body: {'order_id': orderId});

  static Future<Map<String, dynamic>> cancelOrder({
    required String orderId,
    required String role,
  }) =>
      _request('/orders/cancel', method: 'POST', body: {
        'order_id': orderId,
        'role': role,
      });

  static Future<Map<String, dynamic>> markOrderArrived(String orderId) =>
      _request('/orders/arrived', method: 'POST', body: {'order_id': orderId});

  static Future<Map<String, dynamic>> completeOrder({
    required String orderId,
    required int fareSom,
  }) =>
      _request('/orders/complete', method: 'POST', body: {
        'order_id': orderId,
        'fare_som': fareSom,
      });
}

class WorkerApiException implements Exception {
  final String message;
  final int? statusCode;

  const WorkerApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
