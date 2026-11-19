import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  static Future<RoadRoute> drivingRoute(LatLng from, LatLng to) async {
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
      final body = await response.transform(utf8.decoder).join().timeout(_timeout);
      if (response.statusCode != 200) throw const FormatException('Маршрутизатор временно недоступен.');
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['code'] != 'Ok') throw const FormatException('Дорожный маршрут не найден.');
      final routes = data['routes'] as List? ?? const [];
      if (routes.isEmpty) throw const FormatException('Дорожный маршрут не найден.');
      final route = Map<String, dynamic>.from(routes.first as Map);
      final geometry = Map<String, dynamic>.from(route['geometry'] as Map);
      final coordinatesList = geometry['coordinates'] as List? ?? const [];
      final points = coordinatesList.map((item) {
        final pair = item as List;
        return LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble());
      }).toList(growable: false);
      if (points.length < 2) throw const FormatException('Маршрут получен без дорожных точек.');
      return RoadRoute(
        points: points,
        distanceMeters: (route['distance'] as num).toDouble(),
        durationSeconds: (route['duration'] as num).toDouble(),
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
