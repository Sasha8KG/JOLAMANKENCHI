/// Shared GPS timestamp parsing and freshness rules for passenger and driver screens.
const int _maxUnixTimestampMilliseconds = 8640000000000000;

DateTime? _dateTimeFromUnixSeconds(num value) {
  final seconds = value.toDouble();
  if (!seconds.isFinite) return null;
  final milliseconds = seconds * 1000;
  if (!milliseconds.isFinite ||
      milliseconds.abs() > _maxUnixTimestampMilliseconds) {
    return null;
  }
  try {
    return DateTime.fromMillisecondsSinceEpoch(milliseconds.round());
  } catch (_) {
    return null;
  }
}

DateTime? parseGpsTimestamp(dynamic value) {
  if (value is num) return _dateTimeFromUnixSeconds(value);
  final text = (value ?? '').toString().trim();
  if (text.isEmpty || text.length > 64) return null;
  // Some compatible Worker responses serialize Unix seconds as JSON strings.
  if (RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$').hasMatch(text)) {
    final seconds = double.tryParse(text);
    return seconds == null ? null : _dateTimeFromUnixSeconds(seconds);
  }
  return DateTime.tryParse(text);
}

/// Returns the GPS age in whole seconds, or null when the timestamp is missing.
int? calculateGpsAgeSeconds(DateTime? updatedAt, {DateTime? now}) {
  if (updatedAt == null) return null;
  return (now ?? DateTime.now()).difference(updatedAt).inSeconds;
}

/// A timestamp is fresh only when it is not in the future and is at most maxAge old.
bool isGpsTimestampFresh(
  DateTime? updatedAt, {
  DateTime? now,
  Duration maxAge = const Duration(seconds: 60),
}) {
  if (updatedAt == null || maxAge.isNegative) return false;
  final age = (now ?? DateTime.now()).difference(updatedAt);
  // Compare full Duration precision: inSeconds truncates future offsets below 1s to zero.
  return !age.isNegative && age <= maxAge;
}
