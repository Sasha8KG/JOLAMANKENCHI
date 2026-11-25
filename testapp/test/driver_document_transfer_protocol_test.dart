import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sulyukta_taxi/services/driver_document_store.dart';
import 'package:sulyukta_taxi/services/driver_document_transfer_protocol.dart';

void main(){
  group('DriverDocumentTransferProtocol',(){
    const id='123e4567-e89b-12d3-a456-426614174000';
    const uid='driver_UID_123';
    test('10 KiB chunk round-trips below the packet cap',(){
      final bytes=Uint8List.fromList(List<int>.generate(10240,(i)=>i%251));
      final packet=DriverDocumentTransferProtocol.encodeChunks(requestId:id,driverUid:uid,
        documentType:'license',bytes:bytes).single;
      expect(packet.length,lessThanOrEqualTo(DriverDocumentTransferProtocol.maxPacketBytes));
      final chunk=DriverDocumentTransferProtocol.decodeChunk(packet);
      expect(chunk.payload,orderedEquals(bytes));
      expect(chunk.digest,DriverDocumentTransferProtocol.sha256Of(bytes));
    });
    test('splits file and preserves final short chunk',(){
      final bytes=Uint8List.fromList(List<int>.generate(10277,(i)=>i%239));
      final chunks=DriverDocumentTransferProtocol.encodeChunks(requestId:id,driverUid:uid,
        documentType:'car_photo',bytes:bytes).map(DriverDocumentTransferProtocol.decodeChunk).toList();
      expect(chunks,hasLength(2));
      expect(chunks[0].payload,hasLength(10240));
      expect(chunks[1].payload,hasLength(37));
      expect(chunks.map((c)=>c.index),[0,1]);
    });
    test('rejects unsafe identity, oversized document and malformed packet',(){
      expect(()=>DriverDocumentTransferProtocol.encodeChunks(requestId:id,driverUid:'../bad',
        documentType:'license',bytes:Uint8List.fromList([1])).toList(),throwsFormatException);
      expect(()=>DriverDocumentTransferProtocol.chunkCountFor(
        DriverDocumentTransferProtocol.maxDocumentBytes+1),throwsFormatException);
      expect(()=>DriverDocumentTransferProtocol.decodeChunk([123,34]),throwsFormatException);
    });

    test('reassembles chunks received out of order and tolerates identical retry',(){
      final bytes=Uint8List.fromList(List<int>.generate(25001,(i)=>i%239));
      final chunks=DriverDocumentTransferProtocol.encodeChunks(requestId:id,driverUid:uid,
        documentType:'license',bytes:bytes).map(DriverDocumentTransferProtocol.decodeChunk).toList();
      final receiver=DriverDocumentTransferAssembler();
      expect(receiver.add(chunks[2]),isTrue);
      expect(receiver.add(chunks[0]),isTrue);
      expect(receiver.add(chunks[0]),isFalse);
      expect(receiver.isComplete,isFalse);
      expect(receiver.add(chunks[1]),isTrue);
      expect(receiver.isComplete,isTrue);
      expect(receiver.assemble(),orderedEquals(bytes));
    });
    test('does not assemble before all parts arrive',(){
      final bytes=Uint8List.fromList(List<int>.generate(15000,(i)=>i%239));
      final chunks=DriverDocumentTransferProtocol.encodeChunks(requestId:id,driverUid:uid,
        documentType:'driver_photo',bytes:bytes).map(DriverDocumentTransferProtocol.decodeChunk).toList();
      final receiver=DriverDocumentTransferAssembler()..add(chunks.first);
      expect(receiver.assemble,throwsFormatException);
    });
    test('acknowledgement retains request, document and chunk sequence',(){
      final packet=DriverDocumentTransferProtocol.encodeAck(requestId:id,driverUid:uid,
        documentType:'driver_photo',index:17);
      final ack=DriverDocumentTransferProtocol.decodeAck(packet);
      expect(ack.requestId,id);expect(ack.driverUid,uid);
      expect(ack.documentType,'driver_photo');expect(ack.index,17);
    });
  });
  group('DriverDocumentStore',(){
    late Directory root;
    setUp(()async{root=await Directory.systemTemp.createTemp('jol-doc-store-');});
    tearDown(()async{if(await root.exists())await root.delete(recursive:true);});
    test('saves private local bytes and verifies SHA-256',()async{
      final bytes=Uint8List.fromList(List<int>.generate(4096,(i)=>i%251));
      final saved=await DriverDocumentStore.persistBytes(root:root,uid:'driver_UID_123',
        documentType:'license',bytes:bytes);
      expect(await File(saved.path).readAsBytes(),orderedEquals(bytes));
      expect(saved.size,bytes.length);
      expect(saved.sha256Hex,DriverDocumentTransferProtocol.sha256Of(bytes));
      expect(saved.toReceipt()['type'],'license');
    });
    test('rejects unsafe uid, unknown type, empty and oversized file',(){
      expect(()=>DriverDocumentStore.persistBytes(root:root,uid:'../bad',
        documentType:'license',bytes:Uint8List.fromList([1])),throwsFormatException);
      expect(()=>DriverDocumentStore.persistBytes(root:root,uid:'driver1',
        documentType:'unknown',bytes:Uint8List.fromList([1])),throwsFormatException);
      expect(()=>DriverDocumentStore.persistBytes(root:root,uid:'driver1',
        documentType:'license',bytes:Uint8List(0)),throwsFormatException);
      expect(()=>DriverDocumentStore.persistBytes(root:root,uid:'driver1',
        documentType:'license',bytes:Uint8List(DriverDocumentStore.maxDocumentBytes+1)),
        throwsFormatException);
    });
  });
}
