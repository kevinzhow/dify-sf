/// Dify launch URLs use plain values; embedded links gzip then base64 them.
/// Only declared Start inputs are read. Identity and sys variables never come
/// from a URL; gzip expansion is bounded before bytes reach a form.
library;

import 'dart:convert';

import 'package:archive/archive.dart';

Map<String, Object?> publicInputsFromQuery(List<Map<String, Object?>> fields, Map<String, String> query) {
  final result = <String, Object?>{};
  for (final field in fields) {
    final name = field['variable'];
    if (name is! String || name.startsWith('sys.') || name.startsWith('user.')) continue;
    final raw = query[name];
    if (raw == null) continue;
    if (raw.length > 65536) throw const FormatException('Launch input exceeds the size limit');
    var text = raw;
    List<int>? bytes;
    try {
      bytes = base64Decode(base64.normalize(raw));
    } on FormatException {
      bytes = null;
    }
    if (bytes != null && bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      final output = OutputMemoryStream();
      if (!const GZipDecoder().decodeStream(InputMemoryStream(bytes), output, verify: true, maxOutputSize: 65536)) {
        throw const FormatException('Malformed compressed launch input');
      }
      text = utf8.decode(output.getBytes());
    }
    result[name] = switch (field['type']) {
      'number' => num.tryParse(text) ?? text,
      'checkbox' => text.toLowerCase() == 'true',
      'json' || 'json_object' => jsonDecode(text),
      _ => text,
    };
  }
  return result;
}
