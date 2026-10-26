import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

@JS('window.__difyPageReady')
external set _ready(JSBoolean value);
bool _scheduled = false;
void markStartupReadyAfterFrame() {
  if (_scheduled) return;
  _scheduled = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _ready = true.toJS;
    web.window.dispatchEvent(web.Event('dify-page-ready'));
  });
}
