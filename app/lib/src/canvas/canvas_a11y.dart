import 'dart:async';

import 'package:flutter/widgets.dart';

import 'canvas_graph.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';

/// The canvas's own compact semantics: one node per on-screen card (title, type, status, selected; tap selects),
/// or one summary when more than [maxCards] are on screen. Cards themselves stay out of the semantics tree (a tree
/// of every card costs more than the rest of the frame). Rebuilt when the view rests and at most every 250 ms for
/// other changes.
class CanvasA11y extends ChangeNotifier {
  CanvasA11y({required this.graph, required this.view, required this.selection, required this.onTap});

  final CanvasGraph graph;
  final CanvasViewState view;
  final CanvasSelection selection;
  final void Function(CanvasNode node) onTap;

  static const maxCards = 200;

  List<(Rect, CanvasNode)> cards = const [];
  String? summary;
  Timer? _timer;

  /// The view moved: rebuild once it has rested for 150 ms.
  void viewMoved() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 150), rebuild);
  }

  /// Content, status or selection changed: rebuild within 250 ms.
  void changed() => _timer ??= Timer(const Duration(milliseconds: 250), rebuild);

  void rebuild() {
    _timer?.cancel();
    _timer = null;
    if (view.viewport.isEmpty) return;
    final visible = view.visible;
    final on = [
      for (final slot in graph.grid.near(visible))
        if (graph.slots[slot] case final n? when visible.overlaps(n.rect)) n,
    ];
    if (on.length <= maxCards) {
      cards = [for (final n in on) (view.rectToScreen(n.rect), n)];
      summary = null;
    } else {
      final byStatus = <String, int>{};
      for (final n in on) {
        byStatus.update(n.status.value, (c) => c + 1, ifAbsent: () => 1);
      }
      final parts = [
        for (final e in byStatus.entries)
          if (e.key != 'idle') '${e.value} ${e.key}',
      ];
      cards = [
        for (final n in on)
          if (selection.nodes.contains(n.slot)) (view.rectToScreen(n.rect), n),
      ];
      summary = '${on.length} nodes in view${parts.isEmpty ? '' : ', ${parts.join(', ')}'}. Zoom in to read them.';
    }
    notifyListeners();
  }

  String label(CanvasNode n) {
    final node = n.node.value;
    return [
      node.title.isEmpty ? node.id : node.title,
      '${node.type} node',
      if (n.status.value != 'idle') n.status.value,
      if (selection.nodes.contains(n.slot)) 'selected',
    ].join(', ');
  }

  Widget build() => ListenableBuilder(
    listenable: this,
    builder: (context, _) => Stack(
      children: [
        if (summary != null) Positioned.fill(child: Semantics(container: true, label: summary)),
        for (final (r, n) in cards)
          Positioned.fromRect(
            rect: r,
            child: Semantics(
              container: true,
              button: true,
              selected: selection.nodes.contains(n.slot),
              label: label(n),
              onTap: () => onTap(n),
            ),
          ),
      ],
    ),
  );

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
