// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow-organize.spec.tsx
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/workflow_editor/organize/workflow_organize.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart';

LayoutInfo info(num x, num y, num width, num height, [int? layer]) =>
    LayoutInfo(x: x.toDouble(), y: y.toDouble(), width: width.toDouble(), height: height.toDouble(), layer: layer);

void main() {
  group('useWorkflowOrganize', () {
    // The spec mocks getLayoutForChildNodes / getLayoutByELK; the calls are recorded here.
    var childCalls = <String>[], rootCalls = 0;
    late WorkflowOrganize organize;

    WorkflowOrganize organizer(Harness h, {LayoutResult? child, LayoutResult? root}) => WorkflowOrganize(
      controller: h.controller,
      canvas: h.canvas,
      store: h.store,
      childLayout: (parent, nodes, edges) {
        childCalls.add(parent);
        return child;
      },
      rootLayout: (List<DifyJson> nodes, List<DifyJson> edges) {
        rootCalls++;
        return root ?? const LayoutResult(nodes: {}, bounds: LayoutBounds.zero);
      },
    );

    setUp(() {
      childCalls = [];
      rootCalls = 0;
    });

    testWidgets('resizes containers, lays out nodes, and syncs draft when editable', (t) async {
      final h = await Harness.start(t, [
        node('loop-node', type: 'loop', w: 200, h: 160),
        node('loop-child', parent: 'loop-node', x: 20, y: 20, w: 100, h: 60),
        node('top-node', x: 400, y: 0),
      ]);
      organize = organizer(
        h,
        child: LayoutResult(
          bounds: const LayoutBounds(minX: 0, minY: 0, maxX: 320, maxY: 220),
          nodes: {'loop-child': info(40, 60, 100, 60)},
        ),
        root: LayoutResult(
          bounds: LayoutBounds.zero,
          nodes: {'loop-node': info(10, 20, 360, 260, 0), 'top-node': info(500, 30, 240, 100, 0)},
        ),
      );

      organize.handleLayout();
      await Harness.settle(t);

      // setNodes once: one history step, LayoutOrganize.
      expect(h.controller.undo.past, hasLength(1));
      expect(h.controller.undo.past.single.event, HistoryEvent.layoutOrganize);
      final loop = h['loop-node']!;
      expect((loop.x, loop.y), (10, 20));
      expect(h.graph['loop-node']!.size, const Size(440 - 2, 340 - 2));
      final child = h['loop-child']!;
      expect((child.x, child.y), (100, 120));
      // reactflow.setViewport({x: 0, y: 0, zoom: 0.7}).
      expect(h.canvas.view.scale, 0.7);
      expect(h.canvas.view.toScreen(Offset.zero), Offset.zero);
      // The draft sync: the moves have reached the server.
      expect(h.controller.status.pending, 0);
      expect(h.demo.server.doc.nodes['loop-child']!.x, 100);
      await h.dispose(t);
    });

    testWidgets('skips layout when nodes are read-only', (t) async {
      final h = await Harness.start(t, [node('n1')]);
      h.store.setCanvasReadOnly(true);
      final view = (h.canvas.view.center, h.canvas.view.scale);
      organize = organizer(h);

      organize.handleLayout();
      await Harness.settle(t);

      expect(childCalls, isEmpty);
      expect(rootCalls, 0);
      expect(h.controller.undo.past, isEmpty);
      expect((h.canvas.view.center, h.canvas.view.scale), view);
      await h.dispose(t);
    });
  });
}
