import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

class DriverDocumentStore {
  DriverDocumentStore._();
  static const maxDocumentBytes=8*1024*1024;
  static const documentTypes={'license','driver_photo','car_photo'};
  static final _uid=RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');

  static Future<StoredDriverDocument> persistPickedImage({
    required String uid, required String documentType, required XFile source,
  }) async {
    final root=await getApplicationDocumentsDirectory();
    final size=await source.length();
    if(size<1 || size>maxDocumentBytes) throw const FormatException('Фото пустое или превышает 8 МБ.');
    final bytes=await source.readAsBytes();
    if(bytes.length!=size) throw const FormatException('Фотография изменилась во время сохранения.');
    return persistBytes(root:root,uid:uid,documentType:documentType,bytes:bytes);
  }

  static Future<StoredDriverDocument> persistBytes({
    required Directory root, required String uid, required String documentType,
    required Uint8List bytes,
  }) async {
    if(!_uid.hasMatch(uid) || !documentTypes.contains(documentType)) {
      throw const FormatException('Недопустимый идентификатор или тип документа.');
    }
    if(bytes.isEmpty || bytes.length>maxDocumentBytes) {
      throw const FormatException('Фото пустое или превышает 8 МБ.');
    }
    final sep=Platform.pathSeparator;
    final dir=Directory(root.path+sep+'driver_documents'+sep+uid);
    await dir.create(recursive:true);
    final target=File(dir.path+sep+documentType+'.image');
    final temp=File(dir.path+sep+'.'+documentType+'.'+DateTime.now().microsecondsSinceEpoch.toString()+'.tmp');
    final digest=sha256.convert(bytes).toString();
    try {
      await temp.writeAsBytes(bytes,flush:true);
      final saved=await temp.readAsBytes();
      if(saved.length!=bytes.length || sha256.convert(saved).toString()!=digest) {
        throw const FileSystemException('Не удалось проверить сохранённую фотографию.');
      }
      if(await target.exists()) await target.delete();
      final result=await temp.rename(target.path);
      return StoredDriverDocument(uid:uid,documentType:documentType,path:result.path,
        size:bytes.length,sha256Hex:digest);
    } catch (_) {
      if(await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  static Future<File?> find({required String uid,required String documentType}) async {
    if(!_uid.hasMatch(uid) || !documentTypes.contains(documentType)) return null;
    final root=await getApplicationDocumentsDirectory();
    final path=root.path+Platform.pathSeparator+'driver_documents'+Platform.pathSeparator+
      uid+Platform.pathSeparator+documentType+'.image';
    final file=File(path);
    return await file.exists()?file:null;
  }
}

class StoredDriverDocument {
  final String uid,documentType,path,sha256Hex;
  final int size;
  const StoredDriverDocument({required this.uid,required this.documentType,
    required this.path,required this.size,required this.sha256Hex});
  Map<String,Object> toReceipt()=>{'type':documentType,'size':size,'sha256':sha256Hex};
}
