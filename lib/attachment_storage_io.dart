import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String?> saveAttachmentCopy({
  required String id,
  required String name,
  required Uint8List bytes,
}) async {
  try {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final attachmentDirectory = Directory(
      [
        documentsDirectory.path,
        'Traveler Attachments',
        _safePathSegment(id),
      ].join(Platform.pathSeparator),
    );
    await attachmentDirectory.create(recursive: true);

    final file = File(
      [
        attachmentDirectory.path,
        _safeFileName(name),
      ].join(Platform.pathSeparator),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } on Object {
    return null;
  }
}

Future<bool> attachmentPathExists(String? path) async {
  if (path == null || path.isEmpty) {
    return false;
  }

  try {
    return File(path).exists();
  } on Object {
    return false;
  }
}

String _safePathSegment(String value) {
  final segment = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
  return segment.isEmpty ? 'attachment' : segment;
}

String _safeFileName(String value) {
  final name = value.trim().isEmpty ? 'attachment' : value.trim();
  final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
  if (sanitized.length <= 160) {
    return sanitized;
  }

  final extensionIndex = sanitized.lastIndexOf('.');
  final extension =
      extensionIndex > 0 && sanitized.length - extensionIndex <= 12
      ? sanitized.substring(extensionIndex)
      : '';
  return '${sanitized.substring(0, 160 - extension.length)}$extension';
}
