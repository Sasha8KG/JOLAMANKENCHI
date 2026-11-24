/// Keeps a passenger's approach route from being reused indefinitely.
/// A matching route is reusable for at most two minutes; after a longer
/// network/GPS interruption the caller must fetch a fresh road route.
class RouteCachePolicy {
  RouteCachePolicy._();

  static const maxAge = Duration(minutes: 2);

  static bool isFresh({
    required String? cachedKey,
    required String requestedKey,
    required DateTime? fetchedAt,
    DateTime? now,
  }) {
    if (cachedKey == null || cachedKey != requestedKey || fetchedAt == null) {
      return false;
    }
    final age = (now ?? DateTime.now()).difference(fetchedAt);
    return !age.isNegative && age <= maxAge;
  }
}
