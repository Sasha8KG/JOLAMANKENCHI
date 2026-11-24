/// Coalesces overlapping refresh requests into one follow-up refresh.
class CoalescedRefreshGate {
  bool _running = false;
  bool _pending = false;

  /// Returns true when the caller owns the refresh slot.
  /// Calls received during an active refresh are coalesced into one retry.
  bool begin() {
    if (_running) {
      _pending = true;
      return false;
    }
    _running = true;
    return true;
  }

  /// Releases the active slot and reports whether one retry was requested.
  bool finish() {
    if (!_running) return false;
    _running = false;
    final shouldRefreshAgain = _pending;
    _pending = false;
    return shouldRefreshAgain;
  }
}
