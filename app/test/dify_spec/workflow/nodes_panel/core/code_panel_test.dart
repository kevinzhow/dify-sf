// dify-spec: web/app/components/workflow/nodes/code/__tests__/panel.spec.tsx
//
// The panel over a document in an in-memory session: what Dify's mocked use-config would be called with is read back
// from the document (the downstream End node shows the output renames and removals).
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'code_harness.dart';

const _code = 'function main({ foo }) { return { result: foo } }';

final _nodes = difyNodes([
  difyNode('start', 'start', {
    'variables': [
      {'variable': 'foo', 'label': 'Foo', 'type': 'text-input', 'required': true},
    ],
  }),
  difyNode('code-node', 'code', {
    'code_language': 'javascript',
    'code': _code,
    'variables': [
      {
        'variable': 'foo',
        'value_selector': ['start', 'foo'],
        'value_type': 'string',
      },
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  }, 'Code'),
  difyNode('end', 'end', {
    'outputs': [
      {
        'variable': 'r',
        'value_selector': ['code-node', 'result'],
      },
    ],
  }),
]);

Finder inputWith(String value) => find.descendant(
  of: find.byWidgetPredicate((w) => w is DifyInput && w.value == value),
  matching: find.byType(EditableText),
);

List<Object?> outputNames(CorePanel p) => [for (final o in p.data['outputs']! as List) (o! as Map)['name']];

class _ShortButtons extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      ns == 'common' && key.startsWith('operation.') && key != 'operation.add'
      ? key.substring(10)
      : super.t(ns, key, params);
}

void main() {
  group('code/panel', () {
    testWidgets('renders editable controls and forwards all input, output, and code actions', (t) async {
      final p = await openCodePanel(
        t,
        _nodes,
        'code-node',
        edges: chain(['start', 'code-node', 'end']),
        host: (p) => CorePanelHostData(
          toastError: p.toasts.add,
          codeGenerator: (context, id, language, onGenerated) => DifyIconButton(
            label: 'generate-code',
            onPressed: () => onGenerated('function main(summary, count) { return { result: summary } }'),
            icon: const SizedBox.square(dimension: 16),
          ),
        ),
      );
      expect(findTitle('workflow.nodes.code.inputVars'), findsOneWidget);
      expect(findTitle('workflow.nodes.code.outputVars'), findsOneWidget);
      expect(t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).readOnly, isFalse);
      // The editor title's `uppercase` (CSS) is applied to the trigger's text.
      expect(find.text('JAVASCRIPT'), findsOneWidget);
      // The dialog's buttons fit with short labels (the test font's glyphs are square).
      DifyI18n.current = _ShortButtons();

      // Inputs: sync the signature, add a row.
      await t.tap(buttonNamed('workflow.nodes.code.syncFunctionSignature'));
      await settle(t);
      expect(p.data['code'], 'function main({foo}) { return { result: foo } }');
      await t.tap(buttonNamed('common.operation.add workflow.nodes.code.inputVars'));
      await settle(t);
      expect((p.data['variables']! as List).last, {'variable': '', 'value_selector': <Object?>[]});

      // The code itself, and generated code (inputs from the signature, string outputs from the return).
      t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).onChange!('generated code body');
      await settle(t);
      expect(p.data['code'], 'generated code body');
      await t.tap(buttonNamed('generate-code'));
      await settle(t);
      expect(p.data['code'], 'function main(summary, count) { return { result: summary } }');
      expect([for (final v in p.data['variables']! as List) (v! as Map)['variable']], ['summary', 'count']);
      expect(outputNames(p), ['result']);

      // Outputs: a rename renames the use downstream; a type change; a new output.
      await t.enterText(inputWith('result'), 'answer');
      await settle(t);
      expect(outputNames(p), ['answer']);
      expect(((p.h['end']!.config['outputs'].toString())), contains('{{code-node.answer}}'));
      await t.tap(find.text('String'));
      await settle(t);
      await t.tap(find.text('Number').last);
      await settle(t);
      expect((p.data['outputs']! as List).single, containsPair('type', 'number'));
      await t.tap(buttonNamed('common.operation.add workflow.nodes.code.outputVars'));
      await settle(t);
      expect(outputNames(p), ['answer', 'var_2']);

      // Removing a used output asks first: cancel keeps everything, confirm clears the use downstream only.
      await t.tap(find.byType(RemoveButton).at(2));
      await settle(t);
      expect(find.text('workflow.common.effectVarConfirm.title'), findsOneWidget);
      await t.tap(find.text('cancel'));
      await settle(t);
      expect(find.text('workflow.common.effectVarConfirm.title'), findsNothing);
      await t.tap(find.byType(RemoveButton).at(2));
      await settle(t);
      await t.tap(find.text('confirm'));
      await settle(t);
      expect(outputNames(p), ['answer', 'var_2']);
      expect(((difyDataOf(p.h['end']!)['outputs']! as List).single! as Map)['value_selector'], isEmpty);
      // An unused output goes at once.
      await t.tap(find.byType(RemoveButton).at(3));
      await settle(t);
      expect(outputNames(p), ['answer']);

      // The language: Python3 takes its default code, inputs and outputs.
      await t.tap(find.text('JAVASCRIPT'));
      await settle(t);
      await t.tap(find.text('Python3'));
      await settle(t);
      expect(p.data['code_language'], 'python3');
      expect(p.data['code'], builtinCodeLanguageDefaults['python3']!['code']);
      expect(outputNames(p), ['result']);
      await p.dispose(t);
    });

    testWidgets('removes input actions in readonly mode and passes readonly state to child sections', (t) async {
      final p = await openCodePanel(t, _nodes, 'code-node', readOnly: true);
      expect(buttonNamed('workflow.nodes.code.syncFunctionSignature'), findsNothing);
      expect(buttonNamed('common.operation.add workflow.nodes.code.inputVars'), findsNothing);
      expect(buttonNamed('common.operation.add workflow.nodes.code.outputVars'), findsOneWidget);
      expect(t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).readOnly, isTrue);
      expect(t.widget<VarList>(find.byType(VarList)).readonly, isTrue);
      expect(t.widget<OutputVarList>(find.byType(OutputVarList)).readonly, isTrue);
      await p.dispose(t);
    });
  });
}
