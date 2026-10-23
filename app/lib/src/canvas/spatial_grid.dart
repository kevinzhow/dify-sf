import 'dart:math';
import 'dart:ui';

/// A uniform grid over canvas space: which slots lie near a rectangle, without scanning every node.
class SpatialGrid {
  SpatialGrid({this.cell = 1000, this.margin = 400});

  final double cell;

  /// Queries are widened by this much, so a node indexed by its top-left corner is found wherever it overlaps.
  final double margin;

  final _cells = <(int, int), Set<int>>{};
  final _cellOf = <int, (int, int)>{};

  (int, int) _key(Offset p) => ((p.dx / cell).floor(), (p.dy / cell).floor());

  void put(int slot, Offset topLeft) {
    final k = _key(topLeft);
    if (_cellOf[slot] == k) return;
    remove(slot);
    _cells.putIfAbsent(k, () => {}).add(slot);
    _cellOf[slot] = k;
  }

  void remove(int slot) {
    final k = _cellOf.remove(slot);
    if (k != null) _cells[k]?.remove(slot);
  }

  Iterable<int> near(Rect r) sync* {
    final q = r.inflate(max(margin, 0));
    final a = _key(q.topLeft), b = _key(q.bottomRight);
    for (var cx = a.$1; cx <= b.$1; cx++) {
      for (var cy = a.$2; cy <= b.$2; cy++) {
        final s = _cells[(cx, cy)];
        if (s != null) yield* s;
      }
    }
  }
}
