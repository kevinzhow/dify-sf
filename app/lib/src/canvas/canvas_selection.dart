import 'package:flutter/foundation.dart';

/// Selected nodes (by slot), the selected edge, the hovered node. Listeners get the slots whose look changed.
class CanvasSelection extends ChangeNotifier {
  final nodes = <int>{};
  String? edge;
  int? hovered;

  /// Slots whose selected/hovered state changed in the last notification.
  final changed = <int>{};

  void selectNodes(Iterable<int> slots, {bool toggle = false}) {
    final before = {...nodes};
    if (!toggle) nodes.clear();
    for (final s in slots) {
      if (toggle && before.contains(s)) {
        nodes.remove(s);
      } else {
        nodes.add(s);
      }
    }
    edge = null;
    _notify({...before.difference(nodes), ...nodes.difference(before)});
  }

  void selectEdge(String? id) {
    final before = {...nodes};
    nodes.clear();
    edge = id;
    _notify(before);
  }

  void hover(int? slot) {
    if (slot == hovered) return;
    final old = hovered;
    hovered = slot;
    _notify({?old, ?slot});
  }

  /// A node left the canvas.
  void forget(int slot) {
    final was = nodes.remove(slot) | (hovered == slot);
    if (hovered == slot) hovered = null;
    if (was) _notify({slot});
  }

  void _notify(Set<int> slots) {
    changed
      ..clear()
      ..addAll(slots);
    notifyListeners();
  }
}
