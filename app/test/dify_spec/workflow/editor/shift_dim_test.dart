// dify-spec: web/app/components/workflow/hooks/__tests__/use-shortcuts.spec.ts
// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-interactions.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/run_view.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../hooks/editor_harness.dart';

Future<EditorHarness> start(WidgetTester t, {Widget Function(Widget)? wrap}) async {
  final h = await EditorHarness.start(
    t,
    [
      node('a', x: 50, y: 100),
      node(
        'selected',
        type: 'template-transform',
        x: 350,
        y: 100,
        config: {
          'variables': VList([
            VMap({
              'variable': const VString('x'),
              'value_selector': const VList([VString('a'), VString('text')]),
            }),
          ]),
        },
      ),
      node(
        'downstream',
        type: 'template-transform',
        x: 650,
        y: 100,
        config: {
          'variables': VList([
            VMap({
              'variable': const VString('x'),
              'value_selector': const VList([VString('selected'), VString('output')]),
            }),
          ]),
        },
      ),
      node('unrelated', x: 50, y: 400),
    ],
    edges: const [
      Edge(id: 'as', source: 'a', target: 'selected'),
      Edge(id: 'sd', source: 'selected', target: 'downstream'),
    ],
    wrap: wrap,
  );
  h.controller.selectNode('selected');
  await t.pump();
  return h;
}

void main() {
  testWidgets('releasing focus clears Shift inspection even without a key-up event', (t) async {
    final h = await start(t);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(h.canvas.dimming.value, isNotNull);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(h.canvas.dimming.value, isNull);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await h.dispose(t);
  });

  group('useShortcuts', () {
    testWidgets('dims while shift is held and undims when released', (t) async {
      final h = await start(t);
      final graph = h.canvas.graph!;
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(graph['unrelated']!.run.value.opacity, 0.3);
      expect(graph['a']!.run.value.opacity, 1);
      expect(graph['downstream']!.run.value.opacity, 1);
      expect(graph.temporaryEdges, hasLength(2));
      expect(graph.strokeOf(graph.temporaryEdges.first).dashed, isTrue);
      expect(graph.strokeOf(graph.edges.firstWhere((e) => e.id == 'as')).opacity, 0.3);
      h.canvas.nodeRun.value = {'unrelated': const NodeRunView(waiting: true)};
      await t.pump();
      expect(graph['unrelated']!.run.value.opacity, 0.3);
      expect(h.doc.edges, hasLength(2));
      expect(h.controller.undo.past, isEmpty);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(graph.temporaryEdges, isEmpty);
      expect(graph['unrelated']!.run.value.opacity, 0.7);
      await h.dispose(t);
    });

    testWidgets('does not dim when shift is held inside editable inputs', (t) async {
      final h = await start(
        t,
        wrap: (editor) => Stack(
          children: [
            editor,
            const Positioned(left: 900, top: 700, width: 200, child: Material(child: TextField())),
          ],
        ),
      );
      await t.tap(find.byType(TextField));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(h.canvas.dimming.value, isNull);
      expect(h.canvas.graph!['unrelated']!.run.value.opacity, 1);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await h.dispose(t);
    });
  });

  group('useNodesInteractions', () {
    testWidgets('loads nodes/edges from collaborative state for delete, disconnect, dim and undim actions', (t) async {
      final h = await start(t);
      final a = WorkflowActions(controller: h.controller, canvas: h.canvas, store: h.store);
      a.dimOtherNodes();
      expect(h.canvas.graph!['unrelated']!.run.value.opacity, 0.3);
      a.undimAllNodes();
      expect(h.canvas.graph!['unrelated']!.run.value.opacity, 1);
      // Hover colours use the same stroke computation in both renderers and clear when the pointer leaves.
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(h.nodeCenter('a'));
      await t.pump();
      final edge = h.canvas.graph!.edges.firstWhere((e) => e.id == 'as');
      expect(h.canvas.graph!.strokeOf(edge).start, getEdgeColor('running'));
      await mouse.moveTo(const Offset(1100, 750));
      await t.pump();
      expect(h.canvas.graph!.strokeOf(edge).start, getEdgeColor());
      await mouse.removePointer();
      await h.dispose(t);
    });
  });
}
