// dify-spec: web/app/components/workflow/__tests__/keyboard-node-movement.browser.spec.tsx
//
// The browser cases on the real canvas: Tab order through the nodes, the focus ring, movement at canvas scale, and
// the edges following a moved node (their ends come from the nodes' handles).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_a11y.dart';
import 'package:dify_sf_app/src/canvas/edge_curve.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hooks/editor_harness.dart';

const _edges = [
  Edge(id: 'connection', source: 'node', sourceHandle: 'source', target: 'output', targetHandle: 'target'),
];

Future<void> _key(WidgetTester t, LogicalKeyboardKey k, {bool shift = false}) async {
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(k);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await t.pump();
  await EditorHarness.settle(t);
}

FocusNode _focusOf(WidgetTester t, String id) =>
    t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas)).a11y.focusNodeOf(id);

/// The node's card on screen.
Rect _nodeRect(EditorHarness h, String id) => h.canvas.view.rectToScreen(h.canvas.graph![id]!.rect);

/// The edge's bounds on screen.
Rect _edgeRect(EditorHarness h, String id) {
  final e = h.doc.edges[id]!, g = h.canvas.graph!;
  final pts = edgeCurve(g[e.source]!.outPortFor(e.sourceHandle), g[e.target]!.inPort).map(h.screen).toList();
  var r = Rect.fromPoints(pts.first, pts.first);
  for (final p in pts) {
    r = r.expandToInclude(Rect.fromPoints(p, p));
  }
  return r;
}

/// The focus ring (`outline: 2px solid state-accent-solid`) is drawn.
bool _ringShown(WidgetTester t) => find
    .byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.foregroundPainter is NodeFocusRingPainter &&
          (w.foregroundPainter! as NodeFocusRingPainter).visible,
    )
    .evaluate()
    .isNotEmpty;

void main() {
  testWidgets('moves a Tab-focused node without selecting it first, at canvas scale without consuming editor keys', (
    t,
  ) async {
    final h = await EditorHarness.start(
      t,
      [node('node', x: 100, y: 100), node('output', x: 500, y: 200)],
      edges: _edges,
      wrap: (editor) => Column(
        children: [
          Expanded(child: editor),
          const Material(
            child: TextField(decoration: InputDecoration(labelText: 'Code editor')),
          ),
        ],
      ),
    );
    h.canvas.view.scale = 0.5;
    await EditorHarness.settle(t);
    final focus = _focusOf(t, 'node');
    for (var i = 0; i < 12 && !focus.hasPrimaryFocus; i++) {
      await _key(t, LogicalKeyboardKey.tab);
    }
    expect(focus.hasPrimaryFocus, isTrue);
    expect(_ringShown(t), isTrue);
    expect(h.canvas.selection.nodes, isEmpty);
    final initial = _nodeRect(h, 'node'), initialEdge = _edgeRect(h, 'connection');

    await _key(t, LogicalKeyboardKey.arrowRight);
    await _key(t, LogicalKeyboardKey.arrowDown, shift: true);
    expect(_nodeRect(h, 'node').left, initial.left + 2.5);
    expect(_nodeRect(h, 'node').top, initial.top + 10);
    expect(_edgeRect(h, 'connection').left, initialEdge.left + 2.5);
    expect(focus.hasPrimaryFocus, isTrue);

    // Keys typed into an editor are its own.
    await t.tap(find.byType(TextField));
    await t.pump();
    await _key(t, LogicalKeyboardKey.arrowRight);
    expect(_nodeRect(h, 'node').left, initial.left + 2.5);

    // Back on the node: Escape (deselect), then the arrow moves it again.
    focus.requestFocus();
    await t.pump();
    await _key(t, LogicalKeyboardKey.escape);
    await _key(t, LogicalKeyboardKey.arrowRight);
    expect(_nodeRect(h, 'node').left, initial.left + 5);
    await h.dispose(t);
  });

  testWidgets('keeps a connected edge attached when a click-selected node moves with the keyboard', (t) async {
    final h = await EditorHarness.start(t, [
      node('node', x: 100, y: 100),
      node('output', x: 500, y: 200),
    ], edges: _edges);
    h.canvas.view.scale = 0.5;
    await EditorHarness.settle(t);
    await t.tapAt(h.nodeCenter('node'), kind: PointerDeviceKind.mouse);
    await t.pump();
    final initialNode = _nodeRect(h, 'node'), initialEdge = _edgeRect(h, 'connection');

    await _key(t, LogicalKeyboardKey.arrowRight);
    expect(_nodeRect(h, 'node').left, initialNode.left + 2.5);
    expect(_edgeRect(h, 'connection').left, initialEdge.left + 2.5);
    expect(_edgeRect(h, 'connection').right, initialEdge.right);

    await _key(t, LogicalKeyboardKey.arrowLeft, shift: true);
    expect(_nodeRect(h, 'node').left, initialNode.left - 7.5);
    expect(_edgeRect(h, 'connection').left, initialEdge.left - 7.5);
    expect(_edgeRect(h, 'connection').right, initialEdge.right);
    await h.dispose(t);
  });
}
