import 'dart:js_interop';

import 'package:web/web.dart' as web;

void Function() listenForOnline(void Function() onOnline) {
  final callback = ((web.Event _) => onOnline()).toJS;
  web.window.addEventListener('online', callback);
  return () => web.window.removeEventListener('online', callback);
}
