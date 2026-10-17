// dify-spec: web/app/components/workflow/nodes/template-transform/__tests__/integration.spec.tsx
// dify-spec: web/app/components/workflow/nodes/template-transform/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/template-transform/__tests__/use-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/template-transform/__tests__/use-single-run-form-params.spec.ts
//
// The panel over a document in an in-memory session (what Dify's mocked use-config would be called with is read back
// from the document); TemplateConfig is use-config.ts over plain data with a recording `setInputs`.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/code_parser.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/template_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'code_harness.dart';

Map<String, Object?> variable([Map<String, Object?> overrides = const {}]) => {
  'variable': 'input_text',
  'value_selector': ['node-1', 'input_text'],
  'value_type': 'string',
  ...overrides,
};

Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Template Transform',
  'desc': '',
  'type': 'template-transform',
  'variables': [variable()],
  'template': '{{ input_text }}',
  ...overrides,
};

List<Node> _nodes() => difyNodes([
  difyNode('node-1', 'start', {
    'variables': [
      {'variable': 'input_text', 'label': 'Input', 'type': 'text-input', 'required': true},
      {'variable': 'result_text', 'label': 'Result', 'type': 'text-input', 'required': true},
    ],
  }),
  difyNode('template-node', 'template-transform', {
    'variables': [variable()],
    'template': '{{ input_text }}',
  }, 'Template Transform'),
]);

Finder inputWith(String value) => find.descendant(
  of: find.byWidgetPredicate((w) => w is DifyInput && w.value == value),
  matching: find.byType(EditableText),
);

/// Adding an input, renaming it (the template follows), picking a variable from the editor's `/` popup (it is
/// added as an input and inserted), typing the template, the output and the Jinja link.
Future<void> wiresThePanel(WidgetTester t) async {
  final urls = <String>[];
  final p = await openCodePanel(t, _nodes(), 'template-node', edges: chain(['node-1', 'template-node']), urls: urls);
  await t.tap(buttonNamed('common.operation.add workflow.nodes.templateTransform.inputVars'));
  await settle(t);
  expect((p.data['variables']! as List).last, {'variable': '', 'value_selector': <Object?>[]});

  await t.enterText(inputWith('input_text'), 'renamed_input');
  await settle(t);
  expect(((p.data['variables']! as List).first! as Map)['variable'], 'renamed_input');
  expect(p.data['template'], '{{ renamed_input }}');

  t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).onChange!('{{ renamed_input }}/');
  await settle(t);
  await t.tap(find.text('result_text'));
  await settle(t);
  expect((p.data['variables']! as List).last, {
    'variable': 'result_text',
    'value_selector': ['node-1', 'result_text'],
  });
  expect(p.data['template'], '{{ renamed_input }}{{ result_text }}');

  t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).onChange!('{{ renamed_input }}');
  await settle(t);
  expect(p.data['template'], '{{ renamed_input }}');

  // Output Variables opens on a tap (collapsed at first, as in Dify).
  expect(findTitle('workflow.nodes.common.outputVars'), findsOneWidget);
  await t.tap(findTitle('workflow.nodes.common.outputVars'));
  await settle(t);
  expect(find.text('output'), findsOneWidget);
  expect(find.text('string'), findsOneWidget);
  final link = t.widget<Semantics>(
    find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == 'workflow.nodes.templateTransform.codeSupportTip',
    ),
  );
  expect(link.properties.link, isTrue);
  expect(link.properties.linkUrl, Uri.parse(jinjaDocsUrl));
  await t.tap(find.text('workflow.nodes.templateTransform.codeSupportTip'));
  expect(urls, [jinjaDocsUrl]);
  await p.dispose(t);
}

Future<void> hidesAddWhenReadOnly(WidgetTester t) async {
  final p = await openCodePanel(t, _nodes(), 'template-node', readOnly: true);
  expect(buttonNamed('common.operation.add workflow.nodes.templateTransform.inputVars'), findsNothing);
  await p.dispose(t);
}

void main() {
  group('template-transform path', () {
    test('should render the node shell without summary content', () {
      final body = DifyCards.bodyOf('template-transform');
      expect(body.height(BodyContext(_nodes().last, (_) => null)), 0);
    });

    testWidgets('should wire variable list and code editor actions from the panel', wiresThePanel);

    testWidgets('should hide the add-variable operation when the panel is read only', hidesAddWhenReadOnly);
  });

  group('template-transform/panel', () {
    testWidgets('wires variable list and code editor actions', wiresThePanel);

    testWidgets('hides the add-variable operation when the panel is read only', hidesAddWhenReadOnly);
  });

  group('template-transform/use-config', () {
    late List<Map<String, Object?>> setInputs;
    setUp(() => setInputs = []);
    final defaultConfig = {
      'template': '{{ default_input }}',
      'variables': [
        variable({
          'variable': 'default_input',
          'value_selector': ['node-2', 'default_input'],
        }),
      ],
    };

    test('hydrates default config when the template is empty', () {
      TemplateConfig(
        inputs: () => createData({'template': '', 'variables': <Object?>[]}),
        setInputs: setInputs.add,
        defaultConfig: defaultConfig,
      ).init();
      expect(setInputs.single, containsPair('template', '{{ default_input }}'));
    });

    test('updates variables, template text, and renamed placeholders', () {
      final c = TemplateConfig(inputs: createData, setInputs: setInputs.add, defaultConfig: defaultConfig);
      final next = variable({
        'variable': 'renamed_input',
        'value_selector': ['node-2', 'renamed_input'],
      });
      c
        ..handleVarListChange([next])
        ..handleAddVariable(
          variable({
            'variable': 'extra_input',
            'value_selector': ['node-3', 'extra_input'],
          }),
        )
        ..handleVarNameChange('input_text', 'renamed_input')
        ..handleCodeChange('{{ output }}')
        ..handleAddEmptyVariable();
      expect(setInputs[0], containsPair('variables', [next]));
      expect(
        [for (final v in setInputs[1]['variables']! as List) (v! as Map)['variable']],
        [
          'input_text',
          'extra_input',
        ],
      );
      expect(setInputs[2], containsPair('template', '{{ renamed_input }}'));
      expect(setInputs[3], containsPair('template', '{{ output }}'));
      expect((setInputs[4]['variables']! as List).last, {'variable': '', 'value_selector': <Object?>[]});
    });

    test('filters to scalar and collection variables used by template interpolation', () {
      expect(TemplateConfig(inputs: createData, setInputs: setInputs.add).readOnly, isFalse);
      expect(TemplateConfig.filterVar('string'), isTrue);
      expect(TemplateConfig.filterVar('array[object]'), isTrue);
      expect(TemplateConfig.filterVar('file'), isFalse);
    });
  });

  group('template-transform/use-single-run-form-params', () {
    test('exposes variable inputs and forwards single-run changes', () {
      final runInputs = <Map<String, Object?>>[];
      final varInputs = [
        {'label': 'Input Text', 'variable': 'input_text', 'type': 'text-input', 'required': true},
      ];
      final r = varSingleRunFormParams(
        payload: createData(),
        runInputData: {'input_text': 'hello'},
        setRunInputData: runInputs.add,
        toVarInputs: (_) => varInputs,
      );
      expect(r.forms, hasLength(1));
      expect(r.forms.single.inputs, varInputs);
      expect(r.forms.single.values, {'input_text': 'hello'});
      r.forms.single.onChange({'input_text': 'updated'});
      expect(runInputs.single, {'input_text': 'updated'});
      expect(r.getDependentVars(), [
        ['node-1', 'input_text'],
      ]);
      expect(r.getDependentVar('input_text'), ['node-1', 'input_text']);
    });
  });
}
