import 'dart:typed_data';

import 'attachment_storage_stub.dart'
    if (dart.library.io) 'attachment_storage_io.dart'
    as impl;

Future<String?> saveAttachmentCopy({
  required String id,
  required String name,
  required Uint8List bytes,
}) {
  return impl.saveAttachmentCopy(id: id, name: name, bytes: bytes);
}

Future<bool> attachmentPathExists(String? path) {
  return impl.attachmentPathExists(path);
}
