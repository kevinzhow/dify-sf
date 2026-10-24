import 'dart:typed_data';

class HelperAudioPlayer {
  Future<void> play(Uint8List bytes, String mimeType) async =>
      throw UnsupportedError('Audio preview is available in the Web client');
  void stop() {}
  void dispose() {}
}
