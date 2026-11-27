/// Strictly validates the complete order snapshot returned by the Worker.
/// A partial or contradictory response must never replace the last good UI state.
class ServerOrderSnapshot {
  final List<Map<String, dynamic>> openOrders;
  final List<Map<String, dynamic>> assignedOrders;

  const ServerOrderSnapshot({
    required this.openOrders,
    required this.assignedOrders,
  });

  static const int maxOpenOrders = 100;
  // Keep this limit aligned with the Worker /orders/open assignedOrders LIMIT 5.
  static const int maxAssignedOrders = 5;

  static ServerOrderSnapshot parse(Map<String, dynamic> payload) {
    final rawOpen = payload['orders'];
    final rawAssigned = payload['assignedOrders'];
    if (rawOpen is! List || rawAssigned is! List) {
      throw const FormatException('Сервер прислал неполный список заказов.');
    }
    if (rawOpen.length > maxOpenOrders || rawAssigned.length > maxAssignedOrders) {
      throw const FormatException('Сервер прислал слишком много активных заказов.');
    }
    final open = _normalize(rawOpen, expectedStatus: 'new');
    final assigned = _normalize(
      rawAssigned,
      allowedStatuses: const {'driver_assigned', 'arrived'},
    );
    final openIds = open.map((order) => order['id'] as String).toSet();
    if (assigned.any((order) => openIds.contains(order['id']))) {
      throw const FormatException(
        'Один заказ одновременно отмечен свободным и назначенным.',
      );
    }
    return ServerOrderSnapshot(
      openOrders: List.unmodifiable(open),
      assignedOrders: List.unmodifiable(assigned),
    );
  }

  static List<Map<String, dynamic>> _normalize(
    List<dynamic> raw, {
    String? expectedStatus,
    Set<String>? allowedStatuses,
  }) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final value in raw) {
      if (value is! Map) {
        throw const FormatException('Список заказов содержит неверную запись.');
      }
      final Map<String, dynamic> order;
      try {
        order = Map<String, dynamic>.from(value);
      } catch (_) {
        throw const FormatException('Список заказов содержит неверные поля.');
      }
      final primaryId = (order['id'] ?? '').toString().trim();
      final fallbackId = (order['firebase_order_id'] ?? '').toString().trim();
      final id = primaryId.isNotEmpty ? primaryId : fallbackId;
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
          !seen.add(id)) {
        throw const FormatException(
          'Список заказов содержит неверный или повторный номер.',
        );
      }
      if (primaryId.isNotEmpty && fallbackId.isNotEmpty &&
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(fallbackId)) {
        throw const FormatException('Список заказов содержит неверный номер Firebase.');
      }
      final status = (order['status'] ?? '').toString();
      if (expectedStatus != null && status != expectedStatus) {
        throw const FormatException('В списке свободных заказов обнаружен неверный статус.');
      }
      if (allowedStatuses != null && !allowedStatuses.contains(status)) {
        throw const FormatException('В активном списке обнаружен неверный статус заказа.');
      }
      order['id'] = id;
      result.add(order);
    }
    return result;
  }
}
