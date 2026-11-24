import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'gps_freshness.dart';

/// Calculates great-circle distance in kilometres using the haversine formula.
double _distanceKm(LatLng from, LatLng to) {
  const earthRadiusKm = 6371.0088;
  final fromLatitude = from.latitude * math.pi / 180;
  final toLatitude = to.latitude * math.pi / 180;
  final latitudeDelta = (to.latitude - from.latitude) * math.pi / 180;
  final longitudeDelta = (to.longitude - from.longitude) * math.pi / 180;

  final sinLatitude = math.sin(latitudeDelta / 2);
  final sinLongitude = math.sin(longitudeDelta / 2);
  final haversine = (sinLatitude * sinLatitude) +
      (math.cos(fromLatitude) *
          math.cos(toLatitude) *
          sinLongitude *
          sinLongitude);
  final boundedHaversine = haversine.clamp(0.0, 1.0);
  final centralAngle = 2 *
      math.atan2(
        math.sqrt(boundedHaversine),
        math.sqrt(1 - boundedHaversine),
      );
  return earthRadiusKm * centralAngle;
}

/// Filters and ranks fresh driver GPS positions around the passenger pickup.
List<MapEntry<LatLng, DateTime>> selectNearbyDriverLocations({
  required LatLng pickup,
  required Iterable<MapEntry<LatLng, DateTime>> candidates,
  DateTime? now,
  double maxDistanceKm = 20,
  int maxResults = 10,
}) {
  if (!pickup.latitude.isFinite ||
      !pickup.longitude.isFinite ||
      pickup.latitude < -90 ||
      pickup.latitude > 90 ||
      pickup.longitude < -180 ||
      pickup.longitude > 180 ||
      !maxDistanceKm.isFinite ||
      maxDistanceKm < 0 ||
      maxResults <= 0) {
    return <MapEntry<LatLng, DateTime>>[];
  }

  final ranked = <({double distanceKm, MapEntry<LatLng, DateTime> entry})>[];
  for (final entry in candidates) {
    final point = entry.key;
    if (!point.latitude.isFinite ||
        !point.longitude.isFinite ||
        point.latitude < -90 ||
        point.latitude > 90 ||
        point.longitude < -180 ||
        point.longitude > 180 ||
        !isGpsTimestampFresh(entry.value, now: now)) {
      continue;
    }
    final distanceKm = _distanceKm(pickup, point);
    if (!distanceKm.isFinite || distanceKm > maxDistanceKm) continue;
    ranked.add((distanceKm: distanceKm, entry: entry));
  }

  ranked.sort((a, b) {
    // Treat sub-micrometre distance differences as floating-point noise so
    // genuinely equidistant cars are consistently ordered by freshest GPS.
    const distanceTieToleranceKm = 1e-9;
    final distanceDelta = a.distanceKm - b.distanceKm;
    if (distanceDelta.abs() > distanceTieToleranceKm) {
      return distanceDelta.compareTo(0);
    }
    return b.entry.value.compareTo(a.entry.value);
  });
  return ranked.take(maxResults).map((item) => item.entry).toList();
}
