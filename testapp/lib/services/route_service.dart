import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:latlong2/latlong.dart';

class RoadRoute {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  const RoadRoute({required this.points, required this.distanceMeters, required this.durationSeconds});

  String get distanceLabel => distanceMeters >= 1000
      ? '${(distanceMeters / 1000).toStringAsFixed(1)} км'
      : '${distanceMeters.round()} м';
  String get etaLabel {
    final minutes = (durationSeconds / 60).round();
    if (minutes < 60) return '$minutes мин';
    return '${minutes ~/ 60} ч ${minutes % 60} мин';
  }
}

/// OpenStreetMap OSRM demo routing. Coordinates are sent to the public
/// routing service; do not send personal names, phone numbers or order IDs.
class RouteService {
  RouteService._();
  static const _timeout = Duration(seconds: 12);

  static bool _isValidPoint(LatLng point) =>
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude >= -90 &&
      point.latitude <= 90 &&
      point.longitude >= -180 &&
      point.longitude <= 180;

  static Future<RoadRoute> drivingRoute(LatLng from, LatLng to) async {
    if (!_isValidPoint(from) || !_isValidPoint(to)) {
      throw const FormatException('Не удалось построить маршрут: проверьте координаты.');
    }
    // Avoid an unnecessary network request when both points are effectively equal.
    if (const Distance().as(LengthUnit.Meter, from, to) < 1) {
      return RoadRoute(points: [from, to], distanceMeters: 0, durationSeconds: 0);
    }

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final coordinates = '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
      final uri = Uri.https('router.project-osrm.org', '/route/v1/driving/$coordinates', {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'false',
      });
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'JolAmanKenchiTaxi/1.0');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_timeout);
      if (response.contentLength > 2 * 1024 * 1024) {
        throw const FormatException('Ответ маршрутизатора слишком большой.');
      }
      if (response.statusCode != 200) {
        // Do not spend time decoding an error page or an oversized error body.
        unawaited(response.drain<void>());
        throw FormatException('Маршрутизатор временно недоступен (HTTP ${response.statusCode}).');
      }
      // Enforce the response limit while streaming, not only after buffering it.
      final responseBytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) {
          if (builder.length + chunk.length > 2 * 1024 * 1024) {
            throw const FormatException('Ответ маршрутизатора слишком большой.');
          }
          builder.add(chunk);
          return builder;
        },
      ).timeout(_timeout);
      final body = utf8.decode(responseBytes.takeBytes(), allowMalformed: false);
      if (body.trim().isEmpty) {
        throw const FormatException('Маршрутизатор вернул пустой ответ.');
      }
      dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        throw const FormatException('Маршрутизатор вернул некорректные данные.');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Маршрутизатор вернул неверный формат данных.');
      }
      if (decoded['code'] is! String || decoded['code'] != 'Ok') {
        throw const FormatException('Дорожный маршрут не найден.');
      }
      final routes = decoded['routes'];
      if (routes is! List || routes.isEmpty || routes.length > 5 || routes.first is! Map) {
        throw const FormatException('Дорожный маршрут не найден.');
      }
      final route = Map<String, dynamic>.from(routes.first as Map);
      final geometryValue = route['geometry'];
      if (geometryValue is! Map || geometryValue['coordinates'] is! List) {
        throw const FormatException('Маршрут получен без дорожных точек.');
      }
      final coordinatesList = geometryValue['coordinates'] as List;
      if (coordinatesList.length < 2 || coordinatesList.length > 10000) {
        throw const FormatException('Маршрут содержит недостаточно или слишком много точек.');
      }
      final points = <LatLng>[];
      for (final item in coordinatesList) {
        if (item is! List || item.length != 2 ||
            item[0] is! num || item[1] is! num) {
          throw const FormatException('Маршрут содержит повреждённую координату.');
        }
        final longitude = (item[0] as num).toDouble();
        final latitude = (item[1] as num).toDouble();
        final point = LatLng(latitude, longitude);
        if (!_isValidPoint(point)) {
          throw const FormatException('Маршрут содержит координату вне допустимых границ.');
        }
        points.add(point);
      }
      if (points.length < 2) {
        throw const FormatException('Маршрут получен без корректных дорожных точек.');
      }
      if (points.length != coordinatesList.length) {
        throw const FormatException('Не все точки маршрута удалось проверить.');
      }
      // A route with repeated identical coordinates cannot guide the driver.
      if (const Distance().as(LengthUnit.Meter, points.first, points.last) < 1) {
        throw const FormatException('Маршрут не содержит движения между точками.');
      }
      // Validate OSRM's road-snapped endpoints before displaying the route.
      final waypointsValue = decoded['waypoints'];
      if (waypointsValue is! List || waypointsValue.length != 2) {
        throw const FormatException('Маршрутизатор не подтвердил начальную и конечную точки.');
      }
      final snappedPoints = <LatLng>[];
      final snapDistances = <double>[];
      for (final waypointValue in waypointsValue) {
        if (waypointValue is! Map) {
          throw const FormatException('Маршрутизатор вернул неверную точку маршрута.');
        }
        final waypoint = Map<String, dynamic>.from(waypointValue);
        final location = waypoint['location'];
        final snapDistance = waypoint['distance'];
        if (location is! List || location.length != 2 ||
            location[0] is! num || location[1] is! num ||
            snapDistance is! num || !snapDistance.toDouble().isFinite ||
            snapDistance < 0 || snapDistance > 5000) {
          throw const FormatException('Не удалось подтвердить привязку маршрута к дороге.');
        }
        final snapped = LatLng(
          (location[1] as num).toDouble(),
          (location[0] as num).toDouble(),
        );
        if (!_isValidPoint(snapped)) {
          throw const FormatException('Маршрутизатор вернул неверные координаты дороги.');
        }
        snappedPoints.add(snapped);
        snapDistances.add(snapDistance.toDouble());
      }
      final startSnapActual = const Distance().as(LengthUnit.Meter, from, snappedPoints.first);
      final endSnapActual = const Distance().as(LengthUnit.Meter, to, snappedPoints.last);
      if ((startSnapActual - snapDistances.first).abs() > 100 ||
          (endSnapActual - snapDistances.last).abs() > 100) {
        throw const FormatException('Расстояние привязки к дороге не совпадает с координатами заказа.');
      }
      if (const Distance().as(LengthUnit.Meter, points.first, snappedPoints.first) > 250 ||
          const Distance().as(LengthUnit.Meter, points.last, snappedPoints.last) > 250) {
        throw const FormatException('Точки дорожного маршрута не совпадают с его началом и концом.');
      }
      // Check that the returned geometry is continuous and its measured
      // length is reasonably consistent with the server's route distance.
      var geometryLength = 0.0;
      for (var i = 1; i < points.length; i++) {
        final segment = const Distance().as(LengthUnit.Meter, points[i - 1], points[i]);
        if (!segment.isFinite || segment > 50000) {
          throw const FormatException('В дорожной линии обнаружен слишком большой разрыв.');
        }
        geometryLength += segment;
      }
      if (!geometryLength.isFinite || geometryLength <= 0) {
        throw const FormatException('Не удалось проверить длину дорожной линии.');
      }
      final directDistance = const Distance().as(LengthUnit.Meter, from, to);
      final distance = route['distance'];
      final duration = route['duration'];
      if (distance is num && distance.toDouble().isFinite &&
          (geometryLength < distance * 0.5 || geometryLength > distance * 2.0 + 1000)) {
        throw const FormatException('Дорожная линия не соответствует заявленной длине маршрута.');
      }
      if (distance is num && duration is num &&
          distance.toDouble().isFinite && duration.toDouble().isFinite &&
          duration > 0 && distance / duration > 100) {
        throw const FormatException('Время маршрута выглядит неправдоподобно коротким.');
      }
      if (distance is num && distance.toDouble().isFinite &&
          distance < directDistance * 0.5) {
        throw const FormatException('Длина маршрута не соответствует расстоянию между точками.');
      }
      if (distance is! num || duration is! num ||
          !distance.toDouble().isFinite || !duration.toDouble().isFinite ||
          distance <= 0 || duration <= 0 ||
          distance > 10000000 || duration > 604800) {
        throw const FormatException('Маршрутизатор вернул неверную длину или время пути.');
      }
      return RoadRoute(
        points: points,
        distanceMeters: distance.toDouble(),
        durationSeconds: duration.toDouble(),
      );
    } on SocketException {
      throw SocketException('Нет соединения для загрузки маршрута.');
    } on TimeoutException {
      throw TimeoutException('Маршрут загружается слишком долго.');
    } finally {
      client.close(force: true);
    }
  }
}
