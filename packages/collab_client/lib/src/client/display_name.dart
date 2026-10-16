import 'dart:convert';

/// Turns what a user typed into a display name the server accepts (protocol 1.3: 1-64 UTF-8 bytes, no control
/// characters): control characters become spaces, surrounding whitespace is trimmed, and the name is cut at a
/// character boundary to 64 bytes. Null if nothing is left.
String? normalizeDisplayName(String raw) {
  final cleaned = String.fromCharCodes(raw.runes.map((r) => r < 0x20 || r == 0x7f ? 0x20 : r)).trim();
  if (cleaned.isEmpty) return null;
  final out = StringBuffer();
  var bytes = 0;
  for (final r in cleaned.runes) {
    final ch = String.fromCharCode(r);
    final n = utf8.encode(ch).length;
    if (bytes + n > 64) break;
    out.write(ch);
    bytes += n;
  }
  final name = out.toString().trimRight();
  return name.isEmpty ? null : name;
}
