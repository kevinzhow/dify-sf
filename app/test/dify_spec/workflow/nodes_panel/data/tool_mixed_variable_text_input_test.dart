// dify-spec: web/app/components/workflow/nodes/tool/components/mixed-variable-text-input/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/tool/components/mixed-variable-text-input/__tests__/placeholder.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_form.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart' show workflowNodesMapOf;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<void> render(WidgetTester t, Widget child) {
  useDifyTestTranslator();
  return t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 360, child: child),
        ),
      ),
    ),
  );
}

DifyPromptEditor editorOf(WidgetTester t) => t.widget<DifyPromptEditor>(find.byType(DifyPromptEditor));

void main() {
  group('tool/mixed-variable-text-input', () {
    testWidgets('should map workflow variable props into the prompt editor', (t) async {
      final changes = <String>[];
      var manage = 0;
      useDifyTestTranslator();
      const vars = [VarGroup(nodeId: 'tool-node', title: 'Search Tool', vars: [])];
      final nodesMap = workflowNodesMapOf(const [
        Node(id: 'start-node', type: 'start', title: 'Start Title'),
        Node(id: 'tool-node', type: 'tool', title: 'Search Tool'),
      ]);
      await render(
        t,
        MixedVariableTextInput(
          vars: vars,
          nodesMap: nodesMap,
          value: 'initial value',
          onChange: (v, _) => changes.add(v),
          showManageInputField: true,
          onManageInputField: () => manage++,
        ),
      );

      await t.enterText(find.byType(TextField), 'updated value');
      await blur(t);
      expect(changes, ['updated value']);

      final e = editorOf(t);
      expect(e.editable, isTrue);
      final block = e.workflowVariableBlock!;
      expect(block.show, isTrue);
      expect(block.variables, vars);
      expect(block.showManageInputField, isTrue);
      block.onManageInputField!();
      expect(manage, 1);
      expect(block.workflowNodesMap.keys.toSet(), {'tool-node', 'start-node', 'sys'});
      expect(block.workflowNodesMap['tool-node']!.title, 'Search Tool');
      expect(block.workflowNodesMap['start-node']!.type, 'start');
      expect(block.workflowNodesMap['sys']!.title, 'workflow.blocks.start');
      expect(block.workflowNodesMap['sys']!.type, 'start');
      expect(find.byType(MixedInputPlaceholder), findsNothing);
    });

    testWidgets('should disable editing and variable insertion when requested', (t) async {
      await render(t, const MixedVariableTextInput(readOnly: true, disableVariableInsertion: true));
      final e = editorOf(t);
      expect(e.editable, isFalse);
      expect(e.value, '');
      expect(e.workflowVariableBlock!.show, isFalse);
      expect(e.workflowVariableBlock!.variables, isEmpty);
      expect(e.workflowVariableBlock!.workflowNodesMap, isEmpty);
      expect(e.workflowVariableBlock!.showManageInputField, isFalse);
      expect(e.workflowVariableBlock!.onManageInputField, isNull);
      expect(find.byType(MixedInputPlaceholder), findsOneWidget);
    });
  });

  group('tool/mixed-variable-text-input/placeholder', () {
    testWidgets('should insert text and focus the editor for click and slash actions', (t) async {
      await render(t, const MixedVariableTextInput());
      expect(find.text('workflow.nodes.tool.insertPlaceholder1'), findsOneWidget);
      expect(find.text('workflow.nodes.tool.insertPlaceholder2'), findsOneWidget);
      expect(find.text('String'), findsOneWidget);

      await t.tap(find.text('workflow.nodes.tool.insertPlaceholder1'));
      await t.pump();
      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(field.controller!.text, '');

      await t.tap(find.text('workflow.nodes.tool.insertPlaceholder2'));
      await t.pump();
      expect(field.focusNode!.hasFocus, isTrue);
      expect((field.controller! as PromptEditorController).prompt, '/');
    });

    testWidgets('should hide variable insertion affordance and badge when disabled', (t) async {
      await render(t, const MixedInputPlaceholder(disableVariableInsertion: true, hideBadge: true));
      expect(find.text('workflow.nodes.tool.insertPlaceholder1'), findsOneWidget);
      expect(find.text('workflow.nodes.tool.insertPlaceholder2'), findsNothing);
      expect(find.text('String'), findsNothing);
      expect(find.byType(DifyKbd), findsNothing);
      // items-start py-1
      final row = t.widget<Row>(
        find.descendant(of: find.byType(MixedInputPlaceholder), matching: find.byType(Row)).first,
      );
      expect(row.crossAxisAlignment, CrossAxisAlignment.start);
    });
  });
}
