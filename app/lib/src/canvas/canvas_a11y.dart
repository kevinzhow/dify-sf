import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import 'canvas_graph.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';

/// The canvas's own compact semantics: one node per on-screen card (title, type, status, selected; tap selects),
/// or one summary when more than [maxCards] are on screen. Cards themselves stay out of the semantics tree (a tree
/// of every card costs more than the rest of the frame). Rebuilt when the view rests and at most every 250 ms for
/// other changes.
///
/// Each card is also a keyboard stop (React Flow's focusable nodes): Tab reaches it, [onKey] gets its keys, and a
/// keyboard focus shows Dify's ring (`outline: 2px solid state-accent-solid; outline-offset: 4px`).
class CanvasA11y extends ChangeNotifier {
  CanvasA11y({required this.graph, required this.view, required this.selection, required this.onTap, this.onKey});

  final CanvasGraph graph;
  final CanvasViewState view;
  final CanvasSelection selection;
  final void Function(CanvasNode node) onTap;
  final KeyEventResult Function(CanvasNode node, KeyEvent event)? onKey;

  /// One focus node per node id, kept while the node exists.
  final _focusNodes = <String, FocusNode>{};

  FocusNode focusNodeOf(String id) => _focusNodes[id] ??= FocusNode(debugLabel: 'node $id');

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
        byStatus.update(n.status, (c) => c + 1, ifAbsent: () => 1);
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
    // Focus nodes of deleted nodes go once no card uses them.
    final gone = [
      for (final id in _focusNodes.keys)
        if (graph[id] == null) id,
    ];
    if (gone.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final id in gone) {
          if (graph[id] == null) _focusNodes.remove(id)?.dispose();
        }
      });
    }
  }

  String label(CanvasNode n) {
    final node = n.node.value;
    return [
      node.title.isEmpty ? node.id : node.title,
      '${node.type} node',
      if (n.status != 'idle') n.status,
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
            key: ValueKey(n.id),
            // Room for the focus ring around the node's box (its 1 px border, 4 px offset, 2 px ring).
            rect: r.inflate(_ring * view.scale),
            child: _NodeStop(
              focusNode: focusNodeOf(n.id),
              onKey: onKey == null ? null : (e) => onKey!(n, e),
              ring: _ring * view.scale,
              child: Semantics(
                container: true,
                button: true,
                selected: selection.nodes.contains(n.slot),
                label: label(n),
                onTap: () => onTap(n),
              ),
            ),
          ),
      ],
    ),
  );

  /// The node's 1 px border, the ring's 4 px offset and its 2 px width.
  static const _ring = 7.0;

  @override
  void dispose() {
    _timer?.cancel();
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }
}

/// A node's keyboard stop: its keys go to [onKey]; a keyboard focus draws the ring.
class _NodeStop extends StatefulWidget {
  const _NodeStop({required this.focusNode, required this.onKey, required this.ring, required this.child});

  final FocusNode focusNode;
  final KeyEventResult Function(KeyEvent e)? onKey;
  final double ring;
  final Widget child;

  @override
  State<_NodeStop> createState() => _NodeStopState();
}

class _NodeStopState extends State<_NodeStop> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final visible = _focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: widget.onKey == null ? null : (_, e) => widget.onKey!(e),
      // A painter (not a decoration) so the stop takes no pointer events from the cards under it.
      child: CustomPaint(
        foregroundPainter: NodeFocusRingPainter(visible: visible, width: 2 * widget.ring / 7),
        child: Padding(padding: EdgeInsets.all(widget.ring), child: widget.child),
      ),
    );
  }
}

/// Dify's focus ring around a keyboard-focused node: [width] px of `state-accent-solid` along the outside.
class NodeFocusRingPainter extends CustomPainter {
  const NodeFocusRingPainter({required this.visible, required this.width});

  final bool visible;
  final double width;

  /// `state-accent-solid`.
  static Color get color => DifyColors.stateAccentSolid;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    canvas.drawRect(
      (Offset.zero & size).deflate(width / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(NodeFocusRingPainter old) => old.visible != visible || old.width != width;
}
