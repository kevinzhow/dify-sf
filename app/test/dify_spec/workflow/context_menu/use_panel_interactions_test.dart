// dify-spec: web/app/components/workflow/hooks/__tests__/use-panel-interactions.spec.ts
import 'dart:convert';

import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('usePanelInteractions', () {
    testWidgets('handlePaneContextMenu should set the panel context menu target', (t) async {
      final h = await Harness.start(t, [node('n1')]);
      h.store.setContextMenuTarget(const NodeContextMenuTarget('n1'));
      h.actions().handlePaneContextMenu();
      expect(h.store.contextMenuTarget.value, WorkflowContextMenuTarget.panel);
      await h.dispose(t);
    });

    testWidgets('handlePaneContextMenu should sync clipboard from navigator clipboard', (t) async {
      final h = await Harness.start(t, [node('n1')]);
      final clipboardNode = {
        'id': 'clipboard-node',
        'type': 'custom',
        'position': {'x': 0, 'y': 0},
        'data': {'type': 'code', 'title': 'Node', 'desc': ''},
      };
      final clipboardEdge = {'id': 'clipboard-edge', 'source': 'clipboard-node', 'target': 'target-node'};
      h.clipboard = jsonEncode({
        'kind': 'dify-workflow-clipboard',
        'version': '0.6.0',
        'nodes': [clipboardNode],
        'edges': [clipboardEdge],
      });
      h.actions().handlePaneContextMenu();
      await t.pump();
      expect(h.store.clipboardElements.value, [clipboardNode]);
      expect(h.store.clipboardEdges.value, [clipboardEdge]);
      await h.dispose(t);
    });

    testWidgets('handlePaneContextmenuCancel should clear the context menu target', (t) async {
      final h = await Harness.start(t, [node('n1')]);
      h.store.setContextMenuTarget(WorkflowContextMenuTarget.panel);
      h.actions().handlePaneContextmenuCancel();
      expect(h.store.contextMenuTarget.value, isNull);
      await h.dispose(t);
    });
  });
}
