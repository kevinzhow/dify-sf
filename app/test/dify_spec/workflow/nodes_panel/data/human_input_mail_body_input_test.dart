// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/__tests__/mail-body-input.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart' show workflowNodesMapOf;
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('human-input/delivery-method/mail-body-input', () {
    testWidgets('should pass prompt editor config with sys start mapping when a start node is available', (t) async {
      final changes = <String>[];
      const vars = [VarGroup(nodeId: 'start', title: 'Start', vars: [])];
      final nodesMap = workflowNodesMapOf([
        difyNode('start', {'type': 'start', 'title': 'Start Node'}),
        difyNode('answer', {'type': 'answer', 'title': 'Answer Node'}),
      ]);
      await pumpComponent(
        t,
        MailBodyInput(
          value: 'Hello {{#url#}}',
          onChange: changes.add,
          email: EmailContext(nodeId: 'n', vars: vars, nodesMap: nodesMap),
        ),
      );

      final editor = t.widget<DifyPromptEditor>(find.byType(DifyPromptEditor));
      expect(editor.editable, isTrue);
      expect(editor.value, 'Hello {{#url#}}');
      expect(editor.placeholder, isNotNull);
      expect((editor.requestUrlBlock!.show, editor.requestUrlBlock!.selectable), (true, true));
      final block = editor.workflowVariableBlock!;
      expect(block.show, isTrue);
      expect(block.variables, vars);
      expect(
        {for (final e in block.workflowNodesMap.entries) e.key: (e.value.title, e.value.type)},
        {
          'start': ('Start Node', 'start'),
          'answer': ('Answer Node', 'answer'),
          'sys': ('workflow.blocks.start', 'start'),
        },
      );
    });

    testWidgets('should disable editing and omit sys mapping when there is no start node', (t) async {
      final nodesMap = workflowNodesMapOf([
        difyNode('llm', {'type': 'llm', 'title': 'LLM Node'}),
      ]);
      await pumpComponent(
        t,
        MailBodyInput(
          value: '',
          readOnly: true,
          email: EmailContext(nodeId: 'n', nodesMap: nodesMap),
        ),
      );

      final editor = t.widget<DifyPromptEditor>(find.byType(DifyPromptEditor));
      expect(editor.editable, isFalse);
      expect(editor.value, '');
      expect(editor.workflowVariableBlock!.variables, isEmpty);
      expect(editor.workflowVariableBlock!.workflowNodesMap.keys, ['llm']);
    });
  });
}
