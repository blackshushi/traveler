import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

Future<void> copyTextToClipboard(String text) async {
  Object? lastError;

  try {
    await Clipboard.setData(ClipboardData(text: text));
    return;
  } on Object catch (error) {
    lastError = error;
  }

  try {
    await web.window.navigator.clipboard.writeText(text).toDart;
    return;
  } on Object catch (error) {
    lastError = error;
  }

  if (_copyWithHiddenTextArea(text)) {
    return;
  }

  throw StateError('Unable to copy text to clipboard: $lastError');
}

bool _copyWithHiddenTextArea(String text) {
  final body = web.document.body;
  if (body == null) {
    return false;
  }

  final textArea = web.HTMLTextAreaElement()
    ..value = text
    ..readOnly = true;
  textArea.style.cssText = [
    'position: fixed',
    'top: 0',
    'left: 0',
    'width: 1px',
    'height: 1px',
    'padding: 0',
    'border: 0',
    'opacity: 0',
  ].join(';');

  body.appendChild(textArea);
  textArea.focus();
  textArea.select();

  final copied = web.document.execCommand('copy');
  textArea.remove();
  return copied;
}
