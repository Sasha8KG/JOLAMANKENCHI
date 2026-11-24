/// Validates a complete dispatcher dashboard response before it can replace
/// the last known-good screen state.
class DispatcherOverviewSnapshot {
  final List<Map<String, dynamic>> drivers;
  final List<Map<String, dynamic>> orders;
  final List<Map<String, dynamic>> today;
  final List<Map<String, dynamic>> earnings;
  final List<Map<String, dynamic>> closedShifts;
  final String businessDate;

  const DispatcherOverviewSnapshot._({
    required this.drivers,
    required this.orders,
    required this.today,
    required this.earnings,
    required this.closedShifts,
    required this.businessDate,
  });

  static const int maxDrivers = 1000;
  static const int maxOrders = 100;
  static const int maxTodayStatuses = 32;
  static const int maxEarningsRows = 1000;
  static const int maxClosedShifts = 50;

  static DispatcherOverviewSnapshot parse(Map<String, dynamic> payload) {
    final drivers = _readRows(payload, 'drivers', maxDrivers, 'uid');
    final orders = _readRows(payload, 'orders', maxOrders, 'id');
    final today = _readRows(payload, 'today', maxTodayStatuses);
    final earnings = _readRows(payload, 'earnings', maxEarningsRows, 'driver_uid');
    final closedShifts = _readRows(payload, 'closed_shifts', maxClosedShifts);

    for (final row in today) {
      final status = row['status'];
      final count = row['count'];
      if (status is! String || status.trim().isEmpty || status.length > 64 ||
          count is! num || !count.isFinite || count < 0 ||
          count % 1 != 0 || count > 9007199254740991) {
        throw const FormatException('Сервер вернул неверную статистику заказов.');
      }
    }

    final rawDate = payload['business_date'];
    if (rawDate is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(rawDate) ||
        DateTime.tryParse(rawDate) == null) {
      throw const FormatException('Сервер вернул неверную дату рабочего дня.');
    }

    return DispatcherOverviewSnapshot._(
      drivers: List.unmodifiable(drivers),
      orders: List.unmodifiable(orders),
      today: List.unmodifiable(today),
      earnings: List.unmodifiable(earnings),
      closedShifts: List.unmodifiable(closedShifts),
      businessDate: rawDate,
    );
  }

  static List<Map<String, dynamic>> _readRows(
    Map<String, dynamic> payload,
    String key,
    int maxRows, [
    String? uniqueIdKey,
  ]) {
    final raw = payload[key];
    if (raw is! List || raw.length > maxRows) {
      throw FormatException('Сервер вернул неверный список: $key.');
    }
    final seen = <String>{};
    final rows = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) {
        throw FormatException('Список $key содержит повреждённую запись.');
      }
      final Map<String, dynamic> row;
      try {
        row = Map<String, dynamic>.from(item);
      } catch (_) {
        throw FormatException('Список $key содержит неверные поля.');
      }
      if (uniqueIdKey != null) {
        final id = (row[uniqueIdKey] ?? '').toString().trim();
        if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
            !seen.add(id)) {
          throw FormatException('Список $key содержит неверный или повторный идентификатор.');
        }
      }
      rows.add(Map<String, dynamic>.unmodifiable(row));
    }
    return rows;
  }
}
