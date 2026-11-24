import 'gps_freshness.dart';

/// Shared acceptance policy for GPS fixes used to place passengers and taxis.
/// Reject cached, future-dated, malformed, or too imprecise positions.
bool isUsableGpsFix({
  required double latitude,
  required double longitude,
  required double accuracyMeters,
  required DateTime? timestamp,
  DateTime? now,
  double maxAccuracyMeters = 250,
  Duration maxAge = const Duration(seconds: 60),
}) {
  if (!latitude.isFinite || !longitude.isFinite ||
      latitude < -90 || latitude > 90 ||
      longitude < -180 || longitude > 180) {
    return false;
  }
  if (!accuracyMeters.isFinite || accuracyMeters < 0 ||
      !maxAccuracyMeters.isFinite || maxAccuracyMeters < 0 ||
      accuracyMeters > maxAccuracyMeters) {
    return false;
  }
  return isGpsTimestampFresh(timestamp, now: now, maxAge: maxAge);
}
