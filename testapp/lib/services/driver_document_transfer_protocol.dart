import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class DriverDocumentTransferProtocol {
  DriverDocumentTransferProtocol._();
  static const chunkBytes = 10 * 1024;
  static const maxPacketBytes = 14 * 1024;
  static const maxDocumentBytes = 8 * 1024 * 1024;
  static const documentTypes = {'license', 'driver_photo', 'car_photo'};
  static final _request = RegExp(r'^[0-9a-f-]{36}$', caseSensitive: false);
  static final _uid = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');
  static final _sha = RegExp(r'^[a-f0-9]{64}$');

  static String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
  static int chunkCountFor(int size) {
    if (size < 1 || size > maxDocumentBytes) throw const FormatException('Недопустимый размер документа.');
    return (size + chunkBytes - 1) ~/ chunkBytes;
  }

  static Iterable<Uint8List> encodeChunks({
    required String requestId, required String driverUid,
    required String documentType, required Uint8List bytes,
  }) sync* {
    _identity(requestId, driverUid, documentType);
    final count = chunkCountFor(bytes.length);
    final digest = sha256Of(bytes);
    for (var i = 0; i < count; i++) {
      final start = i * chunkBytes;
      final end = (start + chunkBytes < bytes.length) ? start + chunkBytes : bytes.length;
      yield encodeChunk(
        requestId: requestId, driverUid: driverUid, documentType: documentType,
        index: i, count: count, total: bytes.length, digest: digest,
        payload: Uint8List.sublistView(bytes, start, end),
      );
    }
  }

  static Uint8List encodeChunk({
    required String requestId, required String driverUid, required String documentType,
    required int index, required int count, required int total,
    required String digest, required Uint8List payload,
  }) {
    _identity(requestId, driverUid, documentType);
    if (count != chunkCountFor(total) || index < 0 || index >= count || !_sha.hasMatch(digest)) {
      throw const FormatException('Некорректный заголовок части документа.');
    }
    final expected = index == count - 1 ? total - index * chunkBytes : chunkBytes;
    if (payload.length != expected) throw const FormatException('Неверный размер части.');
    final packet = Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1, 'type': 'document_chunk', 'request_id': requestId,
      'driver_uid': driverUid, 'document_type': documentType,
      'chunk_index': index, 'chunk_count': count, 'total_bytes': total,
      'sha256': digest, 'payload': base64Encode(payload),
    })));
    if (packet.length > maxPacketBytes) throw const FormatException('Пакет слишком большой.');
    return packet;
  }

  static DocumentTransferChunk decodeChunk(List<int> packet) {
    if (packet.isEmpty || packet.length > maxPacketBytes) throw const FormatException('Недопустимый размер пакета.');
    final dynamic v;
    try { v = jsonDecode(utf8.decode(packet)); }
    on FormatException { throw const FormatException('Повреждён пакет документа.'); }
    if (v is! Map<String, dynamic> || v['v'] != 1 || v['type'] != 'document_chunk') {
      throw const FormatException('Неизвестный формат пакета.');
    }
    final id=v['request_id'], uid=v['driver_uid'], type=v['document_type'];
    final index=v['chunk_index'], count=v['chunk_count'], total=v['total_bytes'];
    final digest=v['sha256'], encoded=v['payload'];
    if (id is! String || uid is! String || type is! String || index is! int ||
        count is! int || total is! int || digest is! String || encoded is! String) {
      throw const FormatException('В пакете отсутствуют обязательные поля.');
    }
    _identity(id, uid, type);
    if (count != chunkCountFor(total) || index < 0 || index >= count || !_sha.hasMatch(digest)) {
      throw const FormatException('Заголовок пакета не прошёл проверку.');
    }
    final Uint8List payload;
    try { payload=Uint8List.fromList(base64Decode(encoded)); }
    on FormatException { throw const FormatException('Данные части повреждены.'); }
    final expected=index == count-1 ? total-index*chunkBytes : chunkBytes;
    if (payload.length != expected) throw const FormatException('Размер части не совпадает с заголовком.');
    return DocumentTransferChunk(
      requestId:id, driverUid:uid, documentType:type, index:index, count:count,
      total:total, digest:digest, payload:payload,
    );
  }

  static Uint8List encodeAck({
    required String requestId, required String driverUid,
    required String documentType, required int index,
  }) {
    _identity(requestId, driverUid, documentType);
    if (index < 0 || index >= 820) throw const FormatException('Номер подтверждения недопустим.');
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'v':1,'type':'document_ack','request_id':requestId,'driver_uid':driverUid,
      'document_type':documentType,'chunk_index':index,
    })));
  }

  static DocumentTransferAck decodeAck(List<int> packet) {
    if (packet.isEmpty || packet.length > maxPacketBytes) throw const FormatException('Недопустимый размер подтверждения.');
    final dynamic v;
    try { v=jsonDecode(utf8.decode(packet)); }
    on FormatException { throw const FormatException('Повреждено подтверждение.'); }
    if (v is! Map<String,dynamic> || v['v']!=1 || v['type']!='document_ack') {
      throw const FormatException('Неизвестный формат подтверждения.');
    }
    final id=v['request_id'], uid=v['driver_uid'], type=v['document_type'], index=v['chunk_index'];
    if (id is! String || uid is! String || type is! String || index is! int) {
      throw const FormatException('Подтверждение неполное.');
    }
    _identity(id,uid,type);
    if (index<0 || index>=820) throw const FormatException('Номер подтверждения недопустим.');
    return DocumentTransferAck(requestId:id,driverUid:uid,documentType:type,index:index);
  }

  static void _identity(String id,String uid,String type) {
    if (!_request.hasMatch(id) || !_uid.hasMatch(uid) || !documentTypes.contains(type)) {
      throw const FormatException('Недопустимые данные участника передачи.');
    }
  }
}

class DocumentTransferChunk {
  final String requestId,driverUid,documentType,digest;
  final int index,count,total;
  final Uint8List payload;
  const DocumentTransferChunk({required this.requestId,required this.driverUid,
    required this.documentType,required this.index,required this.count,
    required this.total,required this.digest,required this.payload});
}
class DocumentTransferAck {
  final String requestId,driverUid,documentType;
  final int index;
  const DocumentTransferAck({required this.requestId,required this.driverUid,
    required this.documentType,required this.index});
}


/// Reassembles out-of-order LiveKit data packets and verifies the final hash.
class DriverDocumentTransferAssembler {
  String? _requestId, _driverUid, _documentType, _digest;
  int? _count, _total;
  final Map<int, Uint8List> _parts = {};

  int get receivedChunks => _parts.length;
  int get expectedChunks => _count ?? 0;
  bool get isComplete => _count != null && _parts.length == _count;

  /// Returns false for an identical retry; conflicting retries are rejected.
  bool add(DocumentTransferChunk chunk) {
    // Validate even directly constructed objects, not only decoded packets.
    final requestOk = RegExp(r'^[0-9a-f-]{36}$', caseSensitive: false)
        .hasMatch(chunk.requestId);
    final uidOk = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(chunk.driverUid);
    final digestOk = RegExp(r'^[a-f0-9]{64}$').hasMatch(chunk.digest);
    if (!requestOk || !uidOk || !digestOk ||
        !DriverDocumentTransferProtocol.documentTypes.contains(chunk.documentType) ||
        chunk.total < 1 ||
        chunk.total > DriverDocumentTransferProtocol.maxDocumentBytes ||
        chunk.count != DriverDocumentTransferProtocol.chunkCountFor(chunk.total) ||
        chunk.index < 0 || chunk.index >= chunk.count) {
      throw const FormatException('Заголовок части документа не прошёл проверку.');
    }

    final expectedLength = chunk.index == chunk.count - 1
        ? chunk.total - chunk.index * DriverDocumentTransferProtocol.chunkBytes
        : DriverDocumentTransferProtocol.chunkBytes;
    if (chunk.payload.length != expectedLength) {
      throw const FormatException('Размер части документа не совпадает с заголовком.');
    }

    if (_requestId == null) {
      _requestId = chunk.requestId;
      _driverUid = chunk.driverUid;
      _documentType = chunk.documentType;
      _digest = chunk.digest;
      _count = chunk.count;
      _total = chunk.total;
    } else if (_requestId != chunk.requestId ||
        _driverUid != chunk.driverUid ||
        _documentType != chunk.documentType ||
        _digest != chunk.digest ||
        _count != chunk.count ||
        _total != chunk.total) {
      throw const FormatException('Части относятся к разным передачам документов.');
    }

    final previous = _parts[chunk.index];
    if (previous != null) {
      if (previous.length != chunk.payload.length) {
        throw const FormatException('Повторная часть документа отличается.');
      }
      for (var i = 0; i < previous.length; i++) {
        if (previous[i] != chunk.payload[i]) {
          throw const FormatException('Повторная часть документа повреждена.');
        }
      }
      return false;
    }

    _parts[chunk.index] = Uint8List.fromList(chunk.payload);
    return true;
  }

  Uint8List assemble() {
    if (!isComplete || _count == null || _total == null || _digest == null) {
      throw const FormatException('Передача документа ещё не завершена.');
    }
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < _count!; i++) {
      final part = _parts[i];
      if (part == null) {
        throw const FormatException('В передаче отсутствует часть документа.');
      }
      builder.add(part);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != _total ||
        DriverDocumentTransferProtocol.sha256Of(bytes) != _digest) {
      throw const FormatException('Контрольная сумма документа не совпала.');
    }
    return bytes;
  }
}
