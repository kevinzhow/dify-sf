import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Native browser playback preserves the provider's bytes and MIME type. One player per editor, disposed on close.
class HelperAudioPlayer {
  final _audio = web.HTMLAudioElement();
  String? _url;
  int _generation = 0;
  Future<void> play(Uint8List bytes, String mimeType) async {
    stop();
    final generation = _generation;
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
    _url = web.URL.createObjectURL(blob);
    _audio.src = _url!;
    try {
      await _audio.play().toDart;
    } on Object {
      if (generation == _generation) stop();
      rethrow;
    }
  }

  void stop() {
    _generation++;
    _audio.pause();
    _audio.removeAttribute('src');
    _audio.load();
    if (_url case final url?) web.URL.revokeObjectURL(url);
    _url = null;
  }

  void dispose() => stop();
}
