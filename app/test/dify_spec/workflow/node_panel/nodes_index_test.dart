// dify-spec: web/app/components/workflow/nodes/__tests__/index.spec.tsx
//
// Panel (nodes/index.tsx) is dify-sf's WorkflowPanels with a NodePanelBodies registry.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final bodies = NodePanelBodies({
  'start': (context, props) => const Text('start-panel-component'),
  'start-placeholder': (context, props) => const Text('start-placeholder-panel-component'),
});

void main() {
  late Harness h;

  Future<void> render(WidgetTester t) async {
    await t.pumpWidget(panelApp(h, WorkflowPanels(controller: h.controller, canvas: h.canvas, bodies: bodies)));
    await settle(t);
  }

  WorkflowNodePanel? shownPanel(WidgetTester t) => find.byType(WorkflowNodePanel).evaluate().isEmpty
      ? null
      : t.widget<WorkflowNodePanel>(find.byType(WorkflowNodePanel));

  setUp(useDifyTestTranslator);

  group('workflow nodes index', () {
    testWidgets('should render the mapped panel inside the base panel shell for custom nodes', (t) async {
      h = await Harness.start(t, [node('node-1', type: 'start', title: 'Start')]);
      h.controller.selectNode('node-1');
      await render(t);
      expect(shownPanel(t)?.node.id, 'node-1');
      expect(shownPanel(t)?.node.type, 'start');
      expect(find.text('start-panel-component'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('should remount the base panel when a node keeps its id but changes type', (t) async {
      h = await Harness.start(t, [node('node-1', type: 'start-placeholder', title: 'Pick a start node')]);
      h.controller.selectNode('node-1');
      await render(t);
      expect(find.text('start-placeholder-panel-component'), findsOneWidget);
      final before = t.state(find.byType(WorkflowNodePanel));

      // The same id comes back as another type (dify-sf's restore of a deleted node).
      final old = h['node-1']!;
      h.controller.session.edit(const RemoveNode('node-1'));
      h.controller.session.edit(
        RestoreNode(Node(id: 'node-1', type: 'start', title: 'Start', x: old.x, y: old.y, config: old.config)),
      );
      h.controller.selectNode('node-1');
      await settle(t);
      expect(shownPanel(t)?.node.type, 'start');
      expect(find.text('start-panel-component'), findsOneWidget);
      expect(t.state(find.byType(WorkflowNodePanel)), isNot(same(before)));
      await h.dispose(t);
    });

    testWidgets('should return null for non-custom panel types', (t) async {
      h = await Harness.start(t, [node('note-1', type: '', rfType: 'custom-note')]);
      h.controller.selectNode('note-1');
      await render(t);
      expect(find.byType(WorkflowNodePanel), findsNothing);
      await h.dispose(t);
    });
  });
}
