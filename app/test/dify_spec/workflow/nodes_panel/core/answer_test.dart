// dify-spec: web/app/components/workflow/nodes/answer/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/answer/__tests__/use-config.spec.ts
//
// The panel over a document in an in-memory session; the prompt editor is the real one, its props are read back.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/answer_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _nodes = difyNodes([
  difyNode('node-1', 'code', {
    'outputs': {
      'context': {'type': 'string'},
      'items': {'type': 'array[object]'},
    },
  }, 'Node 1'),
  difyNode('answer-node', 'answer', {'variables': <Object?>[], 'answer': 'Initial answer'}, 'Answer'),
]);

Future<CorePanel> _open(WidgetTester t) =>
    openCorePanel(t, _nodes, 'answer-node', edges: chain(['node-1', 'answer-node']));

void main() {
  group('AnswerPanel', () {
    testWidgets('should pass editor state and available variables through to the prompt editor', (t) async {
      final p = await _open(t);
      final editor = t.widget<DifyPromptEditorPanel>(find.byType(DifyPromptEditorPanel));
      expect(editor.readOnly, false);
      expect(editor.title, 'workflow.nodes.answer.answer');
      expect(editor.value, 'Initial answer');
      // The upstream node's variables (array[object] filtered out) and the SYSTEM group.
      expect([for (final g in editor.nodesOutputVars) g.nodeId], ['node-1', 'global']);
      expect(editor.nodesOutputVars.first.vars.map((v) => v.variable), ['context']);
      expect(editor.availableNodes['node-1']?.title, 'Node 1');
      expect(editor.isSupportFileVar, true);
      expect(editor.justVar, true);
      await p.dispose(t);
    });

    testWidgets('should delegate answer edits to use-config', (t) async {
      final p = await _open(t);
      t.widget<DifyPromptEditorPanel>(find.byType(DifyPromptEditorPanel)).onChange('Updated answer');
      await settle(t);
      expect(p.data['answer'], 'Updated answer');
      await p.dispose(t);
    });
  });

  group('answer/use-config', () {
    testWidgets('should update the answer text and expose var-list handlers', (t) async {
      final p = await _open(t);
      final props = NodePanelProps(node: p.node, controller: p.h.controller, actions: panelActions(p.h));
      final config = AnswerConfig(PanelInputs(props), readOnly: props.readOnly);
      config.handleAnswerChange('Updated answer');
      expect(p.data['answer'], 'Updated answer');
      config.handleAddVariable();
      expect(p.data['variables'], [
        {'variable': '', 'value_selector': <Object?>[]},
      ]);
      config.handleVarListChange(const []);
      expect(p.data['variables'], isEmpty);
      expect(config.readOnly, false);
      await p.dispose(t);
    });

    test('should filter out array-object variables from the prompt editor picker', () {
      expect(AnswerConfig.filterVar(const PickerVar('items', 'array[object]'), const []), false);
      expect(AnswerConfig.filterVar(const PickerVar('message', 'string'), const []), true);
    });
  });
}
