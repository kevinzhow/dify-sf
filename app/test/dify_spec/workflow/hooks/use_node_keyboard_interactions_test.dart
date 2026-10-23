// dify-spec: web/app/components/workflow/hooks/__tests__/use-node-keyboard-interactions.spec.tsx
//
// The canvas's nodes are keyboard stops (CanvasA11y): Tab reaches them, Enter / Space select and Escape deselects,
// the arrows move the focused node (or the selection it belongs to); with the canvas focused (a click on a node),
// the arrows move the selection. Each move is one NodeDragStop undo step of moveNode ops (what collaborators
// receive).
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'editor_harness.dart';

Future<void> _key(WidgetTester t, LogicalKeyboardKey k, {bool shift = false}) async {
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(k);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await t.pump();
}

/// Tabs until node [id] has the focus.
Future<void> _tabTo(WidgetTester t, EditorHarness h, String id) async {
  final focus = t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas)).a11y.focusNodeOf(id);
  for (var i = 0; i < 12 && !focus.hasPrimaryFocus; i++) {
    await _key(t, LogicalKeyboardKey.tab);
  }
  expect(focus.hasPrimaryFocus, isTrue, reason: 'Tab reaches node $id');
}

({int x, int y}) _pos(EditorHarness h, String id) => (x: h.doc.nodes[id]!.x, y: h.doc.nodes[id]!.y);

List<String> _selected(EditorHarness h) => [for (final s in h.canvas.selection.nodes) h.canvas.graph!.slots[s]!.id];

void main() {
  group('node keyboard interactions', () {
    testWidgets('moves from the origin, broadcasts the old and new positions, and saves undo history', (t) async {
      final h = await EditorHarness.start(t, [node('node', x: 0, y: 0)]);
      h.canvas.selection.selectNodes([h.canvas.graph!['node']!.slot]);
      await _tabTo(t, h, 'node');
      await _key(t, LogicalKeyboardKey.arrowRight);
      await _key(t, LogicalKeyboardKey.arrowDown, shift: true);
      await EditorHarness.settle(t);
      expect(_pos(h, 'node'), (x: 5, y: 20));
      final past = h.controller.undo.past;
      expect(past, hasLength(2));
      expect(
        [for (final s in past) (s.event, s.nodeId)],
        [
          (HistoryEvent.nodeDragStop, 'node'),
          (HistoryEvent.nodeDragStop, 'node'),
        ],
      );
      // Undo takes back the last move only: the old position comes back.
      h.controller.undo.undo();
      expect(_pos(h, 'node'), (x: 5, y: 0));
      await h.dispose(t);
    });

    testWidgets('selects and deselects the focused node while leaving editor keys alone', (t) async {
      final title = TextEditingController();
      addTearDown(title.dispose);
      final h = await EditorHarness.start(
        t,
        [node('node', x: 0, y: 0)],
        wrap: (editor) => Column(
          children: [
            Expanded(child: editor),
            Material(
              child: TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Node title'),
              ),
            ),
          ],
        ),
      );
      await _tabTo(t, h, 'node');
      await _key(t, LogicalKeyboardKey.enter);
      expect(_selected(h), ['node']);
      expect(h.controller.selectedNodeId, 'node');
      await _key(t, LogicalKeyboardKey.escape);
      expect(_selected(h), isEmpty);
      expect(h.controller.selectedNodeId, isNull);
      await t.tap(find.byType(TextField));
      await t.pump();
      await _key(t, LogicalKeyboardKey.arrowDown);
      expect(_pos(h, 'node'), (x: 0, y: 0));
      expect(h.controller.undo.past, isEmpty);
      await h.dispose(t);
    });

    testWidgets('moves a Tab-focused unselected node without moving a separate selection', (t) async {
      final h = await EditorHarness.start(t, [node('node', x: 0, y: 0), node('other', x: 400, y: 300)]);
      h.canvas.selection.selectNodes([h.canvas.graph!['other']!.slot]);
      await _tabTo(t, h, 'node');
      await _key(t, LogicalKeyboardKey.arrowRight);
      await EditorHarness.settle(t);
      expect(_pos(h, 'node'), (x: 5, y: 0));
      expect(_pos(h, 'other'), (x: 400, y: 300));
      expect(h.controller.undo.past.single.nodeId, 'node');
      await h.dispose(t);
    });

    testWidgets('moves from the title button through collaboration and keeps its native activation', (t) async {
      final h = await EditorHarness.start(t, [node('node', x: 100, y: 100)]);
      // A click selects the node (and focuses the canvas).
      await t.tapAt(h.nodeCenter('node'), kind: PointerDeviceKind.mouse);
      await t.pump();
      await _key(t, LogicalKeyboardKey.arrowRight);
      await EditorHarness.settle(t);
      expect(_pos(h, 'node'), (x: 105, y: 100));
      expect(h.controller.undo.past, hasLength(1));
      // Enter and Space on the node keep selecting it.
      await _tabTo(t, h, 'node');
      await _key(t, LogicalKeyboardKey.enter);
      await _key(t, LogicalKeyboardKey.space);
      expect(_selected(h), ['node']);
      expect(h.controller.selectedNodeId, 'node');
      await h.dispose(t);
    });

    testWidgets('keeps selected children stationary relative to a moving selected container', (t) async {
      final h = await EditorHarness.start(t, [
        node('node', type: 'iteration', x: 100, y: 100, w: 600, h: 400),
        node('child', x: 30, y: 70, parent: 'node'),
        node('other', x: 900, y: 600),
      ]);
      final g = h.canvas.graph!;
      h.canvas.selection.selectNodes([g['node']!.slot, g['child']!.slot, g['other']!.slot]);
      await _tabTo(t, h, 'other');
      await _key(t, LogicalKeyboardKey.arrowRight);
      await EditorHarness.settle(t);
      expect(
        [_pos(h, 'node'), _pos(h, 'child'), _pos(h, 'other')],
        [
          (x: 105, y: 100),
          (x: 30, y: 70),
          (x: 905, y: 600),
        ],
      );
      await h.dispose(t);
    });

    // The container's React Flow box is 600 x 400 and the child's 242 x 52: (342, 328) is the bottom-right corner it
    // may reach (16 px from the right, 20 px from the bottom), like Dify's (184, 150) in a 300 x 250 box.
    for (final type in ['iteration', 'loop']) {
      testWidgets('clamps a child to its %s container and skips empty history at the boundary', (t) async {
        final h = await EditorHarness.start(t, [
          node('parent', type: type, x: 0, y: 0, w: 600, h: 400),
          node('node', x: 342, y: 328, parent: 'parent'),
        ]);
        h.canvas.selection.selectNodes([h.canvas.graph!['node']!.slot]);
        await _tabTo(t, h, 'node');
        await _key(t, LogicalKeyboardKey.arrowRight);
        await _key(t, LogicalKeyboardKey.arrowDown);
        await EditorHarness.settle(t);
        expect(_pos(h, 'node'), (x: 342, y: 328));
        expect(h.controller.undo.past, isEmpty);
        await h.dispose(t);
      });
    }

    // Dify's `locked` state (a node with `draggable: false`) has no counterpart: dify-sf nodes are always draggable.
    for (final mode in ['readonly', 'comment', 'start']) {
      testWidgets('does not move in %s state', (t) async {
        final h = await EditorHarness.start(t, [
          node('node', type: mode == 'start' ? 'iteration-start' : 'code', x: 0, y: 0),
        ], canEdit: mode != 'readonly');
        if (mode == 'comment') h.store.setControlMode(ControlMode.comment);
        h.canvas.selection.selectNodes([h.canvas.graph!['node']!.slot]);
        await _tabTo(t, h, 'node');
        await _key(t, LogicalKeyboardKey.arrowRight);
        await EditorHarness.settle(t);
        expect(_pos(h, 'node'), (x: 0, y: 0));
        expect(h.controller.undo.past, isEmpty);
        await h.dispose(t);
      });
    }
  });
}
