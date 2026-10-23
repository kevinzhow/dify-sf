// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/node-resizer.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/node-resizer.browser.spec.tsx
//
// NodeResizer is dify-sf's NodeResizers overlay (iteration and loop containers, and notes the canvas draws): the
// resize button at the node's bottom-right corner, writing the node's size to the document.
import 'dart:ui' show SemanticsAction;

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/workflow_editor/canvas_plus/node_resizers.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import '../context_menu/harness.dart';
import '../nodes_panel/core/harness.dart' show difyNodes;

final _container = {
  'id': 'container',
  'type': 'custom',
  'position': {'x': 50, 'y': 70},
  'width': 500,
  'height': 400,
  'data': {'type': 'iteration', 'title': 'Iteration', 'desc': '', 'width': 500, 'height': 400},
};

final _child = {
  'id': 'child',
  'type': 'custom',
  'parentId': 'container',
  'position': {'x': 100, 'y': 100},
  'width': 240,
  'height': 100,
  'data': {'type': 'code', 'title': 'Child', 'isInIteration': true, 'iteration_id': 'container'},
};

final _note = {
  'id': 'note',
  'type': 'custom-note',
  'position': {'x': 100, 'y': 100},
  'width': 300,
  'height': 200,
  'data': {'type': '', 'title': 'Note', 'text': '', 'theme': 'blue', 'author': 'Alice', 'width': 300, 'height': 200},
};

Future<Harness> _render(WidgetTester t, List<Map<String, Object?>> nodes, {bool readOnly = false}) async {
  useDifyTestTranslator();
  final h = await Harness.start(t, difyNodes(nodes));
  final graph = CanvasGraph(layoutOf: const DifyCards().layoutOf)..sync(h.doc);
  h.controller.addListener(() => graph.sync(h.doc));
  h.canvas
    ..graph = graph
    ..view.center = const Offset(400, 300);
  if (readOnly) h.store.canvasReadOnly.value = true;
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: h.store,
          child: Column(
            children: [
              TextButton(onPressed: () {}, child: const Text('Before canvas')),
              Expanded(
                child: NodeResizers(controller: h.controller, canvas: h.canvas),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await Harness.settle(t);
  return h;
}

Finder _control() => find.bySemanticsLabel('common.resize.node');

/// The node's size as the document has it (`data.width × data.height`).
String _size(Harness h, String id) {
  final n = h.doc.nodes[id]!;
  num of(String k) => switch (n.config[k]) {
    VInt(:final value) => value,
    VDouble(:final value) => value,
    _ => -1,
  };
  return '${of('width').round()} × ${of('height').round()}';
}

Future<void> _key(WidgetTester t, LogicalKeyboardKey k, {bool shift = false}) async {
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(k);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await t.pump();
}

/// Focuses the resize control of [id] as Tab would.
Future<void> _focus(WidgetTester t, String id) async {
  t
      .widget<Focus>(
        find.descendant(of: find.byKey(ValueKey('resizer-$id')), matching: find.byType(Focus)).first,
      )
      .focusNode!
      .requestFocus();
  await t.pump();
  await t.pump();
}

double _opacity(WidgetTester t, String id) =>
    t.widget<Opacity>(find.descendant(of: find.byKey(ValueKey('resizer-$id')), matching: find.byType(Opacity))).opacity;

void main() {
  group('NodeResizer', () {
    testWidgets('resizes both dimensions without moving the node and shrinks only as far as its contents allow', (
      t,
    ) async {
      final h = await _render(t, [_container, _child]);
      h.canvas.selection.selectNodes([h.canvas.graph!['container']!.slot]);
      await t.pump();
      await _focus(t, 'container');
      await _key(t, LogicalKeyboardKey.arrowRight);
      await _key(t, LogicalKeyboardKey.arrowDown, shift: true);
      expect(_size(h, 'container'), '508 × 432');
      expect((h.doc.nodes['container']!.x, h.doc.nodes['container']!.y), (50, 70));
      await _key(t, LogicalKeyboardKey.home);
      // The child reaches 100 + 240 + 16 right and its bottom + 20 down (its card's height, which React Flow
      // measures in Dify and the spec stubs as 100).
      final child = h.canvas.graph!['child']!.rect, container = h.canvas.graph!['container']!.rect;
      final fit = '356 × ${(child.bottom - container.top + 20).round()}';
      expect(_size(h, 'container'), fit);
      await _key(t, LogicalKeyboardKey.arrowLeft);
      await _key(t, LogicalKeyboardKey.arrowUp);
      expect(_size(h, 'container'), fit);
      await _key(t, LogicalKeyboardKey.arrowRight);
      await _key(t, LogicalKeyboardKey.arrowDown);
      // Enter clicks the button: a click shrinks to fit.
      await _key(t, LogicalKeyboardKey.enter);
      expect(_size(h, 'container'), fit);
      await _key(t, LogicalKeyboardKey.end);
      expect(_size(h, 'container'), fit);
      await h.dispose(t);
    });

    testWidgets('keeps the resize action available when the node is not selected', (t) async {
      final h = await _render(t, [_container]);
      expect(_control(), findsOneWidget);
      expect(t.getSemantics(_control()).getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      await h.dispose(t);
    });

    testWidgets('does not offer resizing on a readonly canvas', (t) async {
      final h = await _render(t, [_container], readOnly: true);
      expect(_control(), findsNothing);
      await h.dispose(t);
    });
  });

  testWidgets('hides an unselected Note resize handle from pointer targeting until hover or keyboard focus', (t) async {
    final h = await _render(t, [_note]);
    expect(_opacity(t, 'note'), 0);
    // Hidden, a press at the handle reaches what is under it, not the handle.
    expect(
      find
          .descendant(of: find.byKey(const ValueKey('resizer-note')), matching: find.byType(IgnorePointer))
          .evaluate()
          .map((e) => (e.widget as IgnorePointer).ignoring)
          .first,
      isTrue,
    );
    h.canvas.selection.hover(h.canvas.graph!['note']!.slot);
    await t.pump();
    expect(_opacity(t, 'note'), 1);
    h.canvas.selection.hover(null);
    await t.pump();
    expect(_opacity(t, 'note'), 0);
    await _focus(t, 'note');
    expect(_opacity(t, 'note'), 1);
    await h.dispose(t);
  });

  testWidgets('reveals the resize handle on keyboard focus and preserves mouse dragging', (t) async {
    final h = await _render(t, [_note]);
    await _focus(t, 'note');
    expect(_opacity(t, 'note'), 1);
    final at = t.getCenter(find.byKey(const ValueKey('resizer-note')));
    final g = await t.startGesture(at, kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(0, 30));
    await g.up();
    await t.pump();
    expect(_size(h, 'note'), '340 × 230');
    expect((h.doc.nodes['note']!.x, h.doc.nodes['note']!.y), (100, 100));
    await h.dispose(t);
  });
}
