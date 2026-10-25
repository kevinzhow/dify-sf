import 'dart:math';

final Random _secure = Random.secure();

/// A globally unique id for nodes, edges and list items (ids are never reused, so they must not collide
/// between clients): 96 random bits in hex.
String newId(String prefix) {
  final bits = [
    for (var i = 0; i < 3; i++) _secure.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
  ];
  return '$prefix-${bits.join()}';
}

/// RFC 9562 UUID v4 for an idempotent API request. Retain the same value across transport retries.
String newUuid() {
  final bytes = List<int>.generate(16, (_) => _secure.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
