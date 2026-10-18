import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/workflow_editor/organize/workflow_organize.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/hooks/editor_harness.dart';

void main() {
  testWidgets('organize commits once, then both renderers receive interpolated positions for 200ms', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 700, y: 400), node('b', x: 100, y: 100)]);
    final old = h.canvas.graph!['a']!.x;
    WorkflowOrganize(controller: h.controller, canvas: h.canvas, store: h.store).handleLayout();
    await t.pump();
    final target = h.doc.nodes['a']!.x.toDouble();
    expect(target, isNot(old));
    await t.pump(const Duration(milliseconds: 100));
    final halfway = h.canvas.graph!['a']!.x;
    expect(halfway, closeTo((old + target) / 2, 1));
    expect(h.doc.nodes['a']!.x.toDouble(), target);
    expect(h.controller.undo.past, hasLength(1));
    await t.pump(const Duration(milliseconds: 110));
    expect(h.canvas.graph!['a']!.x, target);
    expect(h.controller.undo.past, hasLength(1));
    await h.dispose(t);
  });

  testWidgets('a second layout retargets smoothly and pointer input finishes the transition', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 700, y: 400)]);
    h.store.setNodeAnimation(true);
    h.controller.moveNode('a', 100, 100);
    await t.pump();
    await t.pump(const Duration(milliseconds: 70));
    final current = h.canvas.graph!['a']!.x;
    h.controller.moveNode('a', 400, 100);
    await t.pump();
    expect(h.canvas.graph!['a']!.x, closeTo(current, 1));
    await t.tapAt(const Offset(1100, 700));
    await t.pump();
    expect(h.canvas.graph!['a']!.x, 400);
    expect(h.store.nodeAnimation.value, isFalse);
    expect(find.byType(WorkflowCanvas), findsOneWidget);
    await h.dispose(t);
  });
}
