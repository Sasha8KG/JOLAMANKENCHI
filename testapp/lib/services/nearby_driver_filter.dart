import 'package:latlong2/latlong.dart';
import 'gps_freshness.dart';

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

  final distance = const Distance();
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
    final distanceKm = distance.as(LengthUnit.Kilometer, pickup, point);
    if (!distanceKm.isFinite || distanceKm > maxDistanceKm) continue;
    ranked.add((distanceKm: distanceKm, entry: entry));
  }

  ranked.sort((a, b) {
    final byDistance = a.distanceKm.compareTo(b.distanceKm);
    if (byDistance != 0) return byDistance;
    return b.entry.value.compareTo(a.entry.value);
  });
  return ranked.take(maxResults).map((item) => item.entry).toList();
}
