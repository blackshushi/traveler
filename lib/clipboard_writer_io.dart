import 'package:flutter/services.dart';

Future<void> copyTextToClipboard(String text) {
  return Clipboard.setData(ClipboardData(text: text));
}
