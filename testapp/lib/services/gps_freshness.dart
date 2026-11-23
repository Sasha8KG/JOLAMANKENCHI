/// Shared GPS timestamp parsing and freshness rules for passenger and driver screens.
DateTime? parseGpsTimestamp(dynamic value) {
  if (value is num) {
    final seconds = value.toDouble();
    // Worker timestamps are Unix seconds. Ignore non-finite or out-of-range
    // values so a malformed API response cannot crash the passenger/driver map.
    if (!seconds.isFinite || seconds.abs() > 8640000000000) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000);
    } catch (_) {
      return null;
    }
  }
  final text = (value ?? '').toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

/// Returns the GPS age in whole seconds, or null when the timestamp is missing.
int? calculateGpsAgeSeconds(DateTime? updatedAt, {DateTime? now}) {
  if (updatedAt == null) return null;
  return (now ?? DateTime.now()).difference(updatedAt).inSeconds;
}

/// A timestamp is fresh only when it is not in the future and is at most 60 seconds old.
bool isGpsTimestampFresh(
  DateTime? updatedAt, {
  DateTime? now,
  Duration maxAge = const Duration(seconds: 60),
}) {
  final ageSeconds = calculateGpsAgeSeconds(updatedAt, now: now);
  return ageSeconds != null && ageSeconds >= 0 && ageSeconds <= maxAge.inSeconds;
}
