import 'dart:async';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart';
import 'package:path_provider/path_provider.dart';

import 'driver_document_store.dart';
import 'driver_document_transfer_protocol.dart';
import 'worker_api.dart';

/// LiveKit data-channel transport for documents stored on the driver's phone.
///
/// The dispatcher creates the request and connects first. The driver then
/// connects to the same request-specific room and sends the three local files.
/// Firebase Storage is deliberately not touched by this transport.
class DriverDocumentTransferLiveKit {
  DriverDocumentTransferLiveKit._({
    required this.requestId,
    required this.driverUid,
    required this.isDispatcher,
    required Room room,
  }) : _room = room;

  static const String topic = 'jol-aman-kenchi-driver-documents-v1';
  static const List<String> _documentOrder = [
    'license',
    'driver_photo',
    'car_photo',
  ];

  final String requestId;
  final String driverUid;
  final bool isDispatcher;
  final Room _room;
  late final EventsListener<RoomEvent> _listener;
  final Map<String, DriverDocumentTransferAssembler> _assemblers = {};
  final Map<String, StoredDriverDocument> _received = {};
  final Set<String> _persisting = <String>{};
  final Set<String> _acknowledgedChunks = <String>{};
  bool _disposed = false;
  bool _confirming = false;
  bool _confirmed = false;
  Object? _confirmationError;

  int get receivedDocumentCount => _received.length;
  bool get isConfirmed => _confirmed;
  bool get isComplete => _documentOrder.every(_received.containsKey);
  Object? get confirmationError => _confirmationError;

  static Future<DriverDocumentTransferLiveKit> connect({
    required String requestId,
    required String driverUid,
    required bool isDispatcher,
  }) async {
    final normalizedRequest = requestId.trim();
    final normalizedUid = driverUid.trim();
    if (!RegExp(r'^[0-9a-f-]{36}$', caseSensitive: false)
        .hasMatch(normalizedRequest) ||
        normalizedUid.isEmpty ||
        normalizedUid.length > 128 ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(normalizedUid)) {
      throw const FormatException('Некорректные данные передачи документов.');
    }

    final credentials =
        await WorkerApi.driverDocumentsTransferToken(normalizedRequest);
    final url = (credentials['url'] ?? '').toString().trim();
    final token = (credentials['token'] ?? '').toString().trim();
    final responseRequest = (credentials['request_id'] ?? '').toString();
    final expectedRoom = 'jol-aman-kenchi-docs-' + normalizedRequest.replaceAll('-', '');
    final responseRoom = (credentials['room'] ?? '').toString();
    if (url.isEmpty || token.isEmpty || responseRequest != normalizedRequest ||
        responseRoom != expectedRoom) {
      throw const FormatException('Сервер не выдал корректные параметры передачи документов.');
    }

    final room = Room();
    try {
      final session = DriverDocumentTransferLiveKit._(
        requestId: normalizedRequest,
        driverUid: normalizedUid,
        isDispatcher: isDispatcher,
        room: room,
      );
      session._listener = room.createListener()
        ..on<DataReceivedEvent>(session._handleDataReceived);
      await room.connect(url, token).timeout(const Duration(seconds: 25));
      return session;
    } catch (_) {
      await room.disconnect();
      rethrow;
    }
  }

  /// Sends all locally retained documents from the driver's device.
  /// Each packet is published reliably and remains below the protocol limit.
  Future<void> sendDriverDocuments() async {
    _ensureActive();
    if (isDispatcher) {
      throw StateError('Диспетчер не может отправлять документы водителя.');
    }
    final participant = _room.localParticipant;
    if (participant == null) {
      throw StateError('Канал передачи документов ещё не готов.');
    }

    for (final type in _documentOrder) {
      _ensureActive();
      final file = await DriverDocumentStore.find(
        uid: driverUid,
        documentType: type,
      );
      if (file == null) {
        throw FormatException('На телефоне водителя не найден документ: $type.');
      }
      final length = await file.length();
      if (length < 1 || length > DriverDocumentTransferProtocol.maxDocumentBytes) {
        throw FormatException('Недопустимый размер документа: $type.');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != length) {
        throw FormatException('Не удалось полностью прочитать документ: $type.');
      }

      var chunkIndex = 0;
      for (final packet in DriverDocumentTransferProtocol.encodeChunks(
        requestId: requestId,
        driverUid: driverUid,
        documentType: type,
        bytes: Uint8List.fromList(bytes),
      )) {
        _ensureActive();
        final ackKey = '$type:$chunkIndex';
        chunkIndex++;
        // Only retransmit chunks that the dispatcher has not acknowledged.
        // If an acknowledgement was lost, the duplicate packet is safe and
        // the dispatcher will acknowledge it again.
        if (_acknowledgedChunks.contains(ackKey)) continue;
        await participant.publishData(
          packet,
          reliable: true,
          topic: topic,
        ).timeout(const Duration(seconds: 15));
      }
    }
  }

  void _handleDataReceived(DataReceivedEvent event) {
    if (_disposed || event.topic != topic) return;
    final senderUid = event.participant?.identity;
    if (senderUid == null) return;

    if (!isDispatcher) {
      // The room token is request-scoped. Acknowledgements must also match
      // this exact request and driver before they can suppress retransmission.
      if (senderUid == driverUid) return;
      try {
        final ack = DriverDocumentTransferProtocol.decodeAck(event.data);
        if (ack.requestId != requestId || ack.driverUid != driverUid) return;
        _acknowledgedChunks.add('${ack.documentType}:${ack.index}');
      } catch (_) {
        // Ignore unrelated or malformed data packets.
      }
      return;
    }

    // The request-specific room is access-controlled by the Worker token.
    // Still verify the sender identity and every packet's embedded UID.
    if (senderUid != driverUid) return;
    try {
      final chunk = DriverDocumentTransferProtocol.decodeChunk(event.data);
      if (chunk.requestId != requestId || chunk.driverUid != driverUid) return;
      final assembler = _assemblers.putIfAbsent(
        chunk.documentType,
        DriverDocumentTransferAssembler.new,
      );
      assembler.add(chunk);
      // Do not acknowledge in-memory chunks: the dispatcher may lose them if
      // its app closes before the complete document is written to local disk.
      // Once the document is durable, acknowledge all its chunks below.
      if (_received.containsKey(chunk.documentType)) {
        unawaited(_publishChunkAck(chunk.documentType, chunk.index));
      } else if (assembler.isComplete && _persisting.add(chunk.documentType)) {
        unawaited(_persistCompletedDocument(chunk.documentType, assembler));
      }
    } catch (_) {
      // Ignore malformed or unrelated data packets; a later reliable retry
      // can still complete the document without crashing the radio screen.
    }
  }

  Future<void> _publishChunkAck(String documentType, int index) async {
    if (_disposed || !isDispatcher) return;
    final participant = _room.localParticipant;
    if (participant == null) return;
    try {
      await participant.publishData(
        DriverDocumentTransferProtocol.encodeAck(
          requestId: requestId,
          driverUid: driverUid,
          documentType: documentType,
          index: index,
        ),
        reliable: true,
        topic: topic,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      // The driver will resend unacknowledged chunks on its next retry cycle.
    }
  }

  Future<void> _persistCompletedDocument(
    String type,
    DriverDocumentTransferAssembler assembler,
  ) async {
    if (_disposed || _received.containsKey(type)) return;
    try {
      final bytes = assembler.assemble();
      final root = await getApplicationDocumentsDirectory();
      final saved = await DriverDocumentStore.persistBytes(
        root: root,
        uid: driverUid,
        documentType: type,
        bytes: bytes,
      );
      if (_disposed) return;
      _received[type] = saved;
      // Acknowledge only after the file is durably saved and its hash verified.
      // If an ACK is lost, a duplicate packet will be acknowledged by the
      // receive handler because this document is already in _received.
      for (var index = 0; index < assembler.expectedChunks; index++) {
        await _publishChunkAck(type, index);
      }
      if (isComplete) await _confirmReceipt();
    } catch (_) {
      // Keep the assembler in memory so the dispatcher can retry persistence
      // after reconnecting instead of acknowledging an unsaved file.
    } finally {
      _persisting.remove(type);
    }
  }

  Future<void> _confirmReceipt() async {
    if (_disposed || _confirming || !isComplete) return;
    _confirming = true;
    try {
      final files = _documentOrder
          .map((type) => _received[type]!.toReceipt())
          .toList(growable: false);
      await WorkerApi.confirmDriverDocumentsReceived(
        requestId: requestId,
        driverUid: driverUid,
        files: files,
      );
      _confirmationError = null;
      _confirmed = true;
    } catch (error) {
      _confirmationError = error;
      rethrow;
    } finally {
      _confirming = false;
    }
  }

  /// Retries saving complete documents if a previous local disk write failed.
  /// This is called by the dispatcher's monitor; no receipt is sent until all
  /// three files have actually been persisted and hashed on this device.
  Future<void> retryPendingPersistence() async {
    _ensureActive();
    if (!isDispatcher) return;
    for (final entry in _assemblers.entries.toList(growable: false)) {
      final type = entry.key;
      final assembler = entry.value;
      if (!assembler.isComplete || _received.containsKey(type) ||
          !_persisting.add(type)) {
        continue;
      }
      await _persistCompletedDocument(type, assembler);
    }
  }

  /// Retries the server receipt after a temporary network failure.
  Future<void> retryConfirmation() => _confirmReceipt();

  void _ensureActive() {
    if (_disposed) throw StateError('Передача документов уже закрыта.');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _listener.dispose();
    await _room.disconnect();
    await _room.dispose();
  }
}
