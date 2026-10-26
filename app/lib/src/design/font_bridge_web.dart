import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'font_subsets.dart';

@JS('window.difyFontFailure')
external set _failure(JSFunction value);
@JS('window.difyFontFallback')
external set _provider(JSFunction value);
@JS('window.difyFontFamilies')
external set _families(JSArray<JSString> value);
@JS('window.difyFontInvalidate')
external JSFunction? get _invalidate;

FontSubsetLoader? _loader;
void installFontProvider(FontSubsetLoader loader) {
  _loader = loader;
  _failure = ((JSBoolean value) => loader.reportExternalFailure(value.toDart)).toJS;
  final previousChanged = loader.onChanged;
  loader.onChanged = () {
    _families = loader.families.map((name) => name.toJS).toList().toJS;
    previousChanged?.call();
  };
  _provider =
      ((JSArray<JSNumber> points) => loader
              .ensure(points.toDart.map((cp) => cp.toDartInt))
              .then((remaining) => remaining.map((cp) => cp.toJS).toList().toJS)
              .toJS)
          .toJS;
  web.window.addEventListener('online', (() => invalidateFontProvider()).toJS);
}

void invalidateFontProvider() {
  _loader?.retryFailed();
  _invalidate?.callAsFunction();
}
