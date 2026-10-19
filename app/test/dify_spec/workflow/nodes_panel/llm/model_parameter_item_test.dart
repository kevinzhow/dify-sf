// dify-spec: web/app/components/header/account-setting/model-provider-page/model-parameter-modal/__tests__/parameter-item.spec.tsx
// dify-spec: web/app/components/header/account-setting/model-provider-page/model-parameter-modal/__tests__/parameter-item.select.spec.tsx
// dify-spec: web/app/components/header/account-setting/model-provider-page/model-parameter-modal/__tests__/presets-parameter.spec.tsx
//
// The real tag input and prompt editor stand in for Dify's mocks.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/parameter_item.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_picker_model.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart' show workflowNodesMapOf;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_fixtures.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

ModelParameterRule createRule({
  String name = 'temp',
  String type = 'float',
  bool required = false,
  Object? defaultValue,
  num? min,
  num? max,
  List<String> options = const [],
  Map<String, String>? tagPlaceholder,
}) => ModelParameterRule(
  name: name,
  label: const {'en_US': 'Temperature', 'zh_Hans': 'Temperature'},
  type: type,
  help: const {'en_US': 'Help text', 'zh_Hans': 'Help text'},
  required: required,
  defaultValue: defaultValue,
  min: min,
  max: max,
  options: options,
  tagPlaceholder: tagPlaceholder,
);

Finder get _number => find.descendant(of: find.byType(ParameterNumberInput), matching: find.byType(EditableText));
String _numberText(WidgetTester t) => t.widget<EditableText>(_number).controller.text;

void main() {
  setUp(useDifyTestTranslator);

  Future<void> render(
    WidgetTester t,
    ModelParameterRule rule, {
    Object? value,
    ValueChanged<Object?>? onChange,
    void Function(bool, Object?)? onSwitch,
    bool isInWorkflow = false,
    List<VarGroup>? nodesOutputVars,
    Map<String, WorkflowNodeInfo> availableNodes = const {},
  }) => pumpHost(
    t,
    ParameterItem(
      key: UniqueKey(),
      parameterRule: rule,
      value: value,
      onChange: onChange,
      onSwitch: onSwitch,
      isInWorkflow: isInWorkflow,
      nodesOutputVars: nodesOutputVars,
      availableNodes: availableNodes,
    ),
  );

  group('ParameterItem', () {
    testWidgets('should render float controls and clamp numeric input to max', (t) async {
      final changes = <Object?>[];
      await render(t, createRule(min: 0, max: 1), value: 0.7, onChange: changes.add);
      await t.enterText(_number, '1.4');
      expect(changes.last, 1);
      expect(find.byType(DifySlider), findsOneWidget);
    });

    testWidgets('should clamp float numeric input to min', (t) async {
      final changes = <Object?>[];
      await render(t, createRule(min: 0.1, max: 1), value: 0.7, onChange: changes.add);
      await t.enterText(_number, '0.05');
      expect(changes.last, 0.1);
    });

    testWidgets('should render int controls and clamp numeric input', (t) async {
      final changes = <Object?>[];
      await render(t, createRule(type: 'int', min: 0, max: 10), value: 5, onChange: changes.add);
      await t.enterText(_number, '15');
      expect(changes.last, 10);
      await t.enterText(_number, '-5');
      expect(changes.last, 0);
    });

    testWidgets('should adjust step based on max for int type', (t) async {
      num step() => t.widget<ParameterNumberInput>(find.byType(ParameterNumberInput)).step;
      await render(t, createRule(type: 'int', min: 0, max: 50), value: 5);
      expect(step(), 1);
      await render(t, createRule(type: 'int', min: 0, max: 500), value: 50);
      expect(step(), 10);
      await render(t, createRule(type: 'int', min: 0, max: 2000), value: 50);
      expect(step(), 100);
    });

    testWidgets('should render int input without slider if min or max is missing', (t) async {
      await render(t, createRule(type: 'int', min: 0), value: 5);
      expect(find.byType(DifySlider), findsNothing);
      expect(t.widget<ParameterNumberInput>(find.byType(ParameterNumberInput)).step, 0);
    });

    testWidgets('should render exact string input and propagate text changes', (t) async {
      final changes = <Object?>[];
      await render(
        t,
        createRule(type: 'string', name: 'prompt'),
        value: 'initial',
        onChange: changes.add,
      );
      await t.enterText(find.descendant(of: find.byType(DifyInput), matching: find.byType(EditableText)), 'updated');
      expect(changes.last, 'updated');
    });

    testWidgets('should render textarea for text type', (t) async {
      final changes = <Object?>[];
      await render(
        t,
        createRule(type: 'text'),
        value: 'long text',
        onChange: changes.add,
      );
      final area = find.descendant(of: find.byType(ParameterTextArea), matching: find.byType(EditableText));
      expect(area, findsOneWidget);
      await t.enterText(area, 'new long text');
      expect(changes.last, 'new long text');
    });

    testWidgets('should render select for string with options', (t) async {
      await render(
        t,
        createRule(type: 'string', options: ['a', 'b']),
        value: 'a',
      );
      expect(find.text('a'), findsOneWidget);
    });

    testWidgets('should render tag input for tag type', (t) async {
      final changes = <Object?>[];
      await render(
        t,
        createRule(type: 'tag', tagPlaceholder: {'en_US': 'placeholder', 'zh_Hans': 'placeholder'}),
        value: ['a'],
        onChange: changes.add,
      );
      expect(find.text('placeholder'), findsOneWidget);
      final input = find.descendant(of: find.byType(DifyTagInput), matching: find.byType(EditableText));
      await t.enterText(input, 'tag1');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await settle(t);
      expect(changes.last, ['a', 'tag1']);
    });

    testWidgets('should render boolean radios and update value on click', (t) async {
      final changes = <Object?>[];
      await render(t, createRule(type: 'boolean', defaultValue: false), value: true, onChange: changes.add);
      await t.tap(find.text('False'));
      expect(changes.last, false);
    });

    testWidgets('should name the optional switch after its parameter and toggle it off', (t) async {
      final switches = <(bool, Object?)>[];
      await render(t, createRule(), value: 0.7, onSwitch: (on, v) => switches.add((on, v)));
      final s = find.byWidgetPredicate((w) => w is DifySwitch && w.semanticLabel == 'Temperature');
      await t.tap(s);
      expect(switches, [(false, 0.7)]);
    });

    testWidgets('should not render switch if required or name is stop', (t) async {
      await render(t, createRule(required: true), value: 1);
      expect(find.byType(DifySwitch), findsNothing);
      await render(t, createRule(name: 'stop'), value: 1);
      expect(find.byType(DifySwitch), findsNothing);
    });

    testWidgets('should use default values if value is undefined', (t) async {
      await render(t, createRule(defaultValue: 0.5));
      expect(_numberText(t), '0.5');
      await render(t, createRule(type: 'string', defaultValue: 'hello'));
      expect(t.widget<DifyInput>(find.byType(DifyInput)).value, 'hello');
      await render(t, createRule(type: 'boolean', defaultValue: true));
      expect(find.text('True'), findsOneWidget);
      expect(find.text('False'), findsOneWidget);
      await render(t, createRule());
      expect(_numberText(t), '0');
    });

    testWidgets('should reset input to actual bound value on blur-sm', (t) async {
      await render(t, createRule(min: 0, max: 1));
      await t.enterText(_number, '5');
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(t);
      expect(_numberText(t), '1');
    });

    testWidgets('should render no input for unsupported parameter type', (t) async {
      await render(t, createRule(type: 'unsupported'), value: 0.7);
      expect(find.byType(DifyInput), findsNothing);
      expect(find.byType(ParameterNumberInput), findsNothing);
    });

    group('workflow variable reference', () {
      const vars = [VarGroup(nodeId: 'node1', title: 'LLM Node', vars: [])];
      Map<String, WorkflowNodeInfo> nodesMap() => workflowNodesMapOf(const [
        Node(id: 'node1', type: 'llm', title: 'LLM Node', x: 0, y: 0),
        Node(id: 'start', type: 'start', title: 'Start', x: 0, y: 0),
      ]);
      DifyPromptEditor editor(WidgetTester t) => t.widget<DifyPromptEditor>(find.byType(DifyPromptEditor));

      testWidgets('should build workflowNodesMap and render PromptEditor for string type', (t) async {
        final changes = <Object?>[];
        await render(
          t,
          createRule(type: 'string', name: 'system_prompt'),
          value: 'hello {{#node1.output#}}',
          onChange: changes.add,
          isInWorkflow: true,
          nodesOutputVars: vars,
          availableNodes: nodesMap(),
        );
        final e = editor(t);
        expect(e.workflowVariableBlock!.show, isTrue);
        expect(e.workflowVariableBlock!.variables, vars);
        expect(e.workflowVariableBlock!.workflowNodesMap['node1']!.title, 'LLM Node');
        expect(e.workflowVariableBlock!.workflowNodesMap['sys']!.title, 'workflow.blocks.start');
        expect(e.workflowVariableBlock!.workflowNodesMap['sys']!.type, 'start');
        e.onChange!('updated text');
        expect(changes.last, 'updated text');
      });

      testWidgets('should build workflowNodesMap and render PromptEditor for text type', (t) async {
        final changes = <Object?>[];
        await render(
          t,
          createRule(type: 'text', name: 'user_prompt'),
          value: 'some long text',
          onChange: changes.add,
          isInWorkflow: true,
          nodesOutputVars: vars,
          availableNodes: nodesMap(),
        );
        final e = editor(t);
        expect(e.workflowVariableBlock!.variables, vars);
        expect(e.workflowVariableBlock!.workflowNodesMap, isNotEmpty);
        e.onChange!('new long text');
        expect(changes.last, 'new long text');
      });

      testWidgets('should fall back to plain input when not in workflow mode for string type', (t) async {
        await render(
          t,
          createRule(type: 'string', name: 'system_prompt'),
          value: 'plain',
        );
        expect(find.byType(DifyPromptEditor), findsNothing);
        expect(find.byType(DifyInput), findsOneWidget);
      });

      testWidgets('should return undefined workflowNodesMap when not in workflow mode', (t) async {
        await render(
          t,
          createRule(type: 'string', name: 'system_prompt'),
          value: 'plain',
          availableNodes: nodesMap(),
        );
        expect(find.byType(DifyPromptEditor), findsNothing);
      });
    });
  });

  group('ParameterItem select mode', () {
    testWidgets('should propagate a selected value', (t) async {
      final changes = <Object?>[];
      await pumpHost(
        t,
        ParameterItem(
          parameterRule: const ModelParameterRule(
            name: 'format',
            label: {'en_US': 'Format', 'zh_Hans': 'Format'},
            options: ['json', 'text'],
            help: {'en_US': 'Help', 'zh_Hans': 'Help'},
          ),
          value: 'json',
          onChange: changes.add,
        ),
      );
      await t.tap(find.byType(DifySelect<String>));
      await settle(t);
      await t.tap(find.text('text').last);
      await settle(t);
      expect(changes.last, 'text');
    });
  });

  group('PresetsParameter', () {
    testWidgets('selects a preset', (t) async {
      final selected = <int>[];
      await pumpHost(t, PresetsParameter(onSelect: selected.add));
      await t.tap(named('common.modelProvider.loadPresets'));
      await settle(t);
      await t.tap(find.text('common.model.tone.Creative'));
      expect(selected, [1]);
    });

    testWidgets('hides presets when none of their parameters are supported', (t) async {
      await pumpHost(t, PresetsParameter(onSelect: (_) {}, supportedParameterNames: const ['max_tokens']));
      expect(named('common.modelProvider.loadPresets'), findsNothing);
    });

    test('filters preset values to supported parameters', () {
      expect(getSupportedPresetConfig(1, ['temperature']), {'temperature': 0.8});
    });
  });
}
