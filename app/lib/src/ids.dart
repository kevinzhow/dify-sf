import 'dart:math';

final Random _secure = Random.secure();

/// A globally unique id for nodes, edges and list items (ids are never reused, so they must not collide
/// between clients): 96 random bits in hex.
String newId(String prefix) {
  final bits = [for (var i = 0; i < 3; i++) _secure.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')];
  return '$prefix-${bits.join()}';
}
