// dify-spec: web/app/components/workflow/nodes/tool/__tests__/panel.spec.tsx
//
// panel.tsx with useConfig's result given (ToolConfig.from), as the spec mocks the hook.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_form.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_schema_view.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

JsonMap createSchemaItem(String variable) => {
  'name': variable,
  'variable': variable,
  'label': {'en_US': variable, 'zh_Hans': variable},
  'type': FormType.textInput,
  'required': false,
  'show_on': const <Object?>[],
  'form': 'llm',
};

ToolConfig createConfigResult({
  JsonMap inputs = const {'tool_parameters': <String, Object?>{}, 'tool_configurations': <String, Object?>{}},
  List<JsonMap> toolInputVarSchema = const [],
  List<JsonMap> toolSettingSchema = const [],
  bool isShowAuthBtn = false,
  bool isLoading = false,
  List<ToolOutputItem> outputSchema = const [],
  bool hasObjectOutput = false,
}) => ToolConfig.from(
  inputs: inputs,
  currCollection: const {'name': 'google_search'},
  currTool: const {'name': 'google_search'},
  formSchemas: [
    ...toolInputVarSchema,
    for (final s in toolSettingSchema) {...s, 'form': 'form'},
  ],
  isLoading: isLoading,
  isShowAuthBtn: isShowAuthBtn,
  outputSchema: outputSchema,
  hasObjectOutput: hasObjectOutput,
);

Future<void> renderPanel(
  WidgetTester t,
  ToolConfig config, {
  JsonMap toolSettingValue = const {},
  VoidCallback? onManageInputField,
  SchemaTypeMatcher? match,
}) {
  useDifyTestTranslator();
  return t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: WorkflowStore(),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: ToolPanelView(
                  config: config,
                  toolSettingValue: toolSettingValue,
                  onInputVarChange: (_, [_]) {},
                  onSettingChange: (_, [_]) {},
                  onManageInputField: onManageInputField,
                  matchSchemaType: match ?? (_) => '',
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('ToolPanel', () {
    group('Loading State', () {
      testWidgets('should render loading when config data is still loading', (t) async {
        await renderPanel(t, createConfigResult(isLoading: true));
        expect(find.bySemanticsLabel('Loading'), findsOneWidget);
        expect(find.text('workflow.nodes.tool.inputVars'), findsNothing);
        expect(find.byType(ToolForm), findsNothing);
      });
    });

    group('Form Rendering', () {
      testWidgets('should render input and settings forms and forward the manage input field action', (t) async {
        var manage = 0;
        await renderPanel(
          t,
          createConfigResult(
            inputs: {
              'tool_parameters': {
                'query': {'value': 'weather'},
              },
              'tool_configurations': <String, Object?>{},
            },
            toolInputVarSchema: [createSchemaItem('query')],
            toolSettingSchema: [createSchemaItem('region')],
          ),
          toolSettingValue: {'region': 'us'},
          onManageInputField: () => manage++,
        );
        expect(find.text('WORKFLOW.NODES.TOOL.INPUTVARS'), findsOneWidget);
        expect(find.text('WORKFLOW.NODES.TOOL.SETTINGS'), findsOneWidget);
        expect(find.byType(PanelSplit), findsNWidgets(2));

        final forms = t.widgetList<ToolForm>(find.byType(ToolForm)).toList();
        expect(forms, hasLength(2));
        expect(forms[0].showManageInputField, isTrue);
        expect(forms[1].showManageInputField, isFalse);
        expect(forms[1].onManageInputField, isNull);
        expect(forms[1].value, {'region': 'us'});
        forms[0].onManageInputField!();
        expect(manage, 1);
      });

      testWidgets('should hide editable forms when the auth button is shown but keep output variables visible', (
        t,
      ) async {
        await renderPanel(
          t,
          createConfigResult(
            isShowAuthBtn: true,
            toolInputVarSchema: [createSchemaItem('query')],
            toolSettingSchema: [createSchemaItem('region')],
          ),
        );
        expect(find.text('WORKFLOW.NODES.TOOL.INPUTVARS'), findsNothing);
        expect(find.text('WORKFLOW.NODES.TOOL.SETTINGS'), findsNothing);
        await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
        await t.pump();
        expect(find.text('text'), findsOneWidget);
        expect(find.text('files'), findsOneWidget);
        expect(find.text('json'), findsOneWidget);
        expect(find.byType(ToolForm), findsNothing);
      });
    });

    group('Output Schema', () {
      testWidgets('should render scalar and structured outputs with matched schema types', (t) async {
        await renderPanel(
          t,
          createConfigResult(
            hasObjectOutput: true,
            outputSchema: [
              (name: 'summary', type: 'String', description: 'Summary field', value: {'type': 'string'}),
              (
                name: 'details',
                type: 'Object',
                description: 'Details field',
                value: {'type': 'object', 'properties': <String, Object?>{}},
              ),
            ],
          ),
          match: (v) => v is Map && v['type'] == 'string' ? 'qa_structured' : 'object_structured',
        );
        await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
        await t.pump();
        expect(find.text('summary'), findsOneWidget);
        expect(find.text('string (qa_structured)'), findsOneWidget);
        expect(find.text('Summary field'), findsOneWidget);
        final structured = t.widget<StructureOutputShow>(find.byType(StructureOutputShow));
        final props = (structured.payload['schema']! as Map)['properties']! as Map;
        expect(props.keys, ['details']);
        expect((props['details'] as Map)['schemaType'], 'object_structured');
        expect(find.text('details'), findsOneWidget);
      });

      testWidgets('should render scalar outputs without a schema suffix when no schema type matches', (t) async {
        await renderPanel(
          t,
          createConfigResult(
            outputSchema: [
              (name: 'summary', type: 'String', description: 'Summary field', value: {'type': 'string'}),
            ],
          ),
        );
        await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
        await t.pump();
        final item = t.widget<VarItem>(find.byWidgetPredicate((w) => w is VarItem && w.name == 'summary'));
        expect(item.type, 'string');
        expect(find.textContaining('qa_structured'), findsNothing);
      });
    });
  });
}
