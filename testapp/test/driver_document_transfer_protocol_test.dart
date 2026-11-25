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
    test('assembler rejects malformed public chunk objects before storing bytes',(){
      final bytes=Uint8List.fromList(List<int>.generate(10240,(i)=>i%239));
      final valid=DriverDocumentTransferProtocol.decodeChunk(
        DriverDocumentTransferProtocol.encodeChunks(requestId:id,driverUid:uid,
          documentType:'license',bytes:bytes).single);
      final short=DocumentTransferChunk(requestId:valid.requestId,driverUid:valid.driverUid,
        documentType:valid.documentType,index:valid.index,count:valid.count,total:valid.total,
        digest:valid.digest,payload:Uint8List.fromList([1,2,3]));
      expect(()=>DriverDocumentTransferAssembler().add(short),throwsFormatException);
      final invalidCount=DocumentTransferChunk(requestId:valid.requestId,driverUid:valid.driverUid,
        documentType:valid.documentType,index:valid.index,count:valid.count+1,total:valid.total,
        digest:valid.digest,payload:valid.payload);
      expect(()=>DriverDocumentTransferAssembler().add(invalidCount),throwsFormatException);
    });
    test('assembler detects corrupted complete payload by SHA-256',(){
      final bytes=Uint8List.fromList(List<int>.generate(10240,(i)=>i%239));
      final valid=DriverDocumentTransferProtocol.decodeChunk(
        DriverDocumentTransferProtocol.encodeChunks(requestId:id,driverUid:uid,
          documentType:'license',bytes:bytes).single);
      final altered=DocumentTransferChunk(requestId:valid.requestId,driverUid:valid.driverUid,
        documentType:valid.documentType,index:valid.index,count:valid.count,total:valid.total,
        digest:List<String>.filled(64,'0').join(),payload:valid.payload);
      final receiver=DriverDocumentTransferAssembler()..add(altered);
      expect(receiver.assemble,throwsFormatException);
    });
    test('acknowledgement retains request, document and chunk sequence',(){
      final packet=DriverDocumentTransferProtocol.encodeAck(requestId:id,driverUid:uid,
        documentType:'driver_photo',index:17);
      final ack=DriverDocumentTransferProtocol.decodeAck(packet);
      expect(ack.requestId,id);expect(ack.driverUid,uid);
      expect(ack.documentType,'driver_photo');expect(ack.index,17);
    });
    test('accepts the last valid chunk index and rejects an index beyond the 8 MiB limit',(){
      expect(DriverDocumentTransferProtocol.decodeAck(
        DriverDocumentTransferProtocol.encodeAck(requestId:id,driverUid:uid,
          documentType:'license',index:819)).index,819);
      expect(()=>DriverDocumentTransferProtocol.encodeAck(requestId:id,driverUid:uid,
        documentType:'license',index:820),throwsFormatException);
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
    test('replaces an existing document without leaving temporary files',()async{
      final first=Uint8List.fromList([1,2,3,4]);
      final second=Uint8List.fromList([9,8,7,6,5]);
      final original=await DriverDocumentStore.persistBytes(root:root,uid:'driver_UID_123',
        documentType:'license',bytes:first);
      final replacement=await DriverDocumentStore.persistBytes(root:root,uid:'driver_UID_123',
        documentType:'license',bytes:second);
      expect(replacement.path,original.path);
      expect(await File(replacement.path).readAsBytes(),orderedEquals(second));
      final files=await Directory(root.path).list(recursive:true).toList();
      expect(files.whereType<File>().where((file)=>file.path.endsWith('.tmp')||file.path.endsWith('.bak')),isEmpty);
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
