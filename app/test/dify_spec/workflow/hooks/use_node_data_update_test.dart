// dify-spec: web/app/components/workflow/hooks/__tests__/use-node-data-update.spec.ts
//
// handleNodeDataUpdate is the panels' patchInputs (panel_edit.dart): the given keys merged into the node's data,
// written as document ops (Dify's setNodes); nothing while the nodes are read-only.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel_bodies.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/panel_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart';

NodePanelProps _props(Harness h, String id) =>
    NodePanelProps(node: h[id]!, controller: h.controller, actions: h.actions());

void main() {
  group('useNodeDataUpdate', () {
    group('handleNodeDataUpdate', () {
      testWidgets('should merge data into the target node and call setNodes', (t) async {
        final h = await Harness.start(t, [
          node('n1', title: 'Node 1', config: const {'value': VInt(1)}),
          node('n2', title: 'Node 2', config: const {'value': VInt(2)}),
        ]);
        patchInputs(_props(h, 'n1'), {'value': 99, 'extra': 'x'});
        await t.pump();
        expect(h['n1']!.config['value'], const VInt(99));
        expect(h['n1']!.config['extra'], const VString('x'));
        // The other keys and the other node stay.
        expect(h['n1']!.title, 'Node 1');
        expect(h['n2']!.config['value'], const VInt(2));
        await h.dispose(t);
      });
    });

    group('handleNodeDataUpdateWithSyncDraft', () {
      testWidgets('should do nothing when nodes are read-only', (t) async {
        final h = await Harness.start(t, [
          node('n1', config: const {'value': VInt(1)}),
        ]);
        h.store.setWorkflowRunningData({
          'result': {'status': 'running'},
        });
        patchInputs(_props(h, 'n1'), {'value': 99});
        await t.pump();
        expect(h['n1']!.config['value'], const VInt(1));
        await h.dispose(t);
      });
    });
  });
}
