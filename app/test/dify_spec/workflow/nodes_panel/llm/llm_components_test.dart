import '../../../../support/code_editor_input.dart';
// dify-spec: web/app/components/workflow/nodes/llm/components/__tests__/panel-memory-section.spec.tsx
// dify-spec: web/app/components/workflow/nodes/llm/components/__tests__/panel-output-section.spec.tsx
// dify-spec: web/app/components/workflow/nodes/llm/components/__tests__/prompt-generator-btn.spec.tsx
// dify-spec: web/app/components/workflow/nodes/llm/components/json-schema-config-modal/__tests__/json-importer.spec.tsx
// dify-spec: web/app/components/workflow/nodes/llm/components/json-schema-config-modal/__tests__/json-schema-config.spec.tsx
// dify-spec: web/app/components/workflow/nodes/llm/components/json-schema-config-modal/visual-editor/edit-card/__tests__/advanced-actions.spec.tsx
// dify-spec: web/app/components/workflow/nodes/llm/components/json-schema-config-modal/visual-editor/edit-card/__tests__/type-selector.spec.tsx
//
// The LLM panel's components on their own. Where Dify mocks a child (the prompt Editor, MemoryConfig), the case
// reads the real child's props.
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_json_schema.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/config_prompt.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Widget _host(Widget child, {LlmGroupServices services = LlmGroupServices.empty, double width = 900}) => MaterialApp(
  home: Material(
    child: LlmGroupScope(
      services: services,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(child: child),
        ),
      ),
    ),
  ),
);

Map<String, Object?> _memory(String query) => {
  'window': {'enabled': false, 'size': 10},
  'query_prompt_template': query,
};

/// The JSON importer's code editor (Dify mocks it with a textarea named json-editor).
Future<void> _typeJson(WidgetTester t, String json) async {
  await enterCodeEditorText(t, json, within: find.byType(SchemaJsonEditor));
  await settle(t, 200);
}

void main() {
  setUp(useDifyTestTranslator);

  // Dify's test i18n shows keys (`common.operation.cancel`), far longer than the English texts: a wide screen.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1600, 1200);
    view.devicePixelRatio = 1;
  });
  tearDown(() => TestWidgetsFlutterBinding.instance.platformDispatcher.views.first.resetPhysicalSize());

  group('llm/panel-memory-section', () {
    Widget section({
      bool isChatMode = true,
      bool isChatModel = true,
      bool isCompletionModel = false,
      bool isSnippetFlow = false,
      Map<String, Object?>? memory,
    }) => _host(
      PanelMemorySection(
        readOnly: false,
        isChatMode: isChatMode,
        isChatModel: isChatModel,
        isCompletionModel: isCompletionModel,
        isSnippetFlow: isSnippetFlow,
        memory: memory ?? _memory(''),
        hasSetBlockStatus: (history: false, query: true, context: false),
        promptEnv: const PromptEditorEnv(),
        onQueryChange: (_) {},
        onMemoryChange: (_) {},
      ),
    );

    DifyPromptEditorPanel editor(WidgetTester t) => t.widget(find.byType(DifyPromptEditorPanel));
    MemoryConfig memoryConfig(WidgetTester t) => t.widget(find.byType(MemoryConfig));

    testWidgets('renders the built-in chat memory editor and memory config in chat mode', (t) async {
      await t.pumpWidget(section());
      await settle(t);
      expect(find.text('WORKFLOW.NODES.COMMON.MEMORIES.TITLE'), findsOneWidget);
      expect(editor(t).value, '{{#sys.query#}}\n\n{{#sys.files#}}');
      expect(memoryConfig(t).canSetRoleName, isFalse);
      expect(editor(t).isChatApp, isTrue);
      expect(editor(t).isChatModel, isTrue);
      expect(editor(t).isShowContext, isFalse);
    });

    testWidgets('shows the sys query warning when the memory prompt omits the required placeholder', (t) async {
      await t.pumpWidget(section(memory: _memory('custom prompt')));
      await settle(t);
      expect(find.text('workflow.nodes.llm.sysQueryInUser'), findsOneWidget);
      expect(editor(t).value, 'custom prompt');
    });

    testWidgets('does not show the sys query warning in snippet flows', (t) async {
      await t.pumpWidget(section(memory: _memory('custom prompt'), isSnippetFlow: true));
      await settle(t);
      expect(find.text('workflow.nodes.llm.sysQueryInUser'), findsNothing);
      expect(editor(t).value, 'custom prompt');
    });

    testWidgets('does not default snippet memory prompts to system variables', (t) async {
      await t.pumpWidget(section(isSnippetFlow: true));
      await settle(t);
      expect(editor(t).value, '');
      expect(memoryConfig(t).defaultMemory['query_prompt_template'], '');
    });

    testWidgets('renders nothing outside chat mode', (t) async {
      await t.pumpWidget(section(isChatMode: false, isChatModel: false, isCompletionModel: true));
      await settle(t);
      expect(find.text('WORKFLOW.NODES.COMMON.MEMORIES.TITLE'), findsNothing);
      expect(find.byType(DifyPromptEditorPanel), findsNothing);
      expect(find.byType(MemoryConfig), findsNothing);
    });
  });

  group('llm/panel-output-section', () {
    testWidgets('renders the default output vars and keeps structured output collapsed state', (t) async {
      await t.pumpWidget(
        _host(
          PanelOutputSection(
            readOnly: false,
            structuredOutputEnabled: false,
            structuredOutput: null,
            isModelSupportStructuredOutput: true,
            collapsed: false,
            onCollapse: (_) {},
            onEnableChange: (_) {},
            onChange: (_) {},
          ),
        ),
      );
      await settle(t);
      expect(find.text('text'), findsOneWidget);
      expect(find.text('reasoning_content'), findsOneWidget);
      expect(find.text('usage'), findsOneWidget);
      expect(t.widget<OutputVars>(find.byType(OutputVars)).collapsed, isFalse);
      expect(find.byType(StructureOutput), findsNothing);
    });

    testWidgets('renders the structured output editor and toggles the switch when structured output is enabled', (
      t,
    ) async {
      final toggles = <bool>[];
      await t.pumpWidget(
        _host(
          PanelOutputSection(
            readOnly: false,
            structuredOutputEnabled: true,
            structuredOutput: const {
              'schema': {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
            },
            isModelSupportStructuredOutput: false,
            collapsed: false,
            onCollapse: (_) {},
            onEnableChange: toggles.add,
            onChange: (_) {},
          ),
        ),
      );
      await settle(t);
      expect(find.byType(StructureOutput), findsOneWidget);
      await t.tap(find.byType(DifySwitch));
      await settle(t);
      expect(toggles, [false]);
    });
  });

  group('PromptGeneratorBtn', () {
    testWidgets('should open the prompt generator from the named action', (t) async {
      final generated = Completer<String?>();
      final asked = <String>[];
      final h = await startPanel(
        t,
        [
          (
            'llm',
            'llm',
            {
              'model': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat', 'completion_params': {}},
              'prompt_template': [
                {'id': 'p1', 'role': 'system', 'text': 'old prompt'},
              ],
              'context': {'enabled': false, 'variable_selector': <String>[]},
              'vision': {'enabled': false},
            },
          ),
        ],
        services: LlmGroupServices(
          generatePrompt: (nodeId, current) {
            asked.add('$nodeId:$current');
            return generated.future;
          },
        ),
      );
      await t.tap(find.byWidgetPredicate((w) => w is DifyIconButton && w.label == 'app-debug.operation.automatic'));
      await settle(t);
      expect(asked, ['llm:old prompt']);
      generated.complete('new prompt');
      await settle(t);
      expect(((dataOf(h, 'llm')['prompt_template']! as List).single as Map)['text'], 'new prompt');
      await h.dispose(t);
    });
  });

  group('JsonImporter', () {
    Future<List<Object?>> render(WidgetTester t, {bool editing = false, List<String>? quits}) async {
      final submitted = <Object?>[];
      await t.pumpWidget(
        _host(
          Center(
            child: JsonImporter(
              onSubmit: submitted.add,
              isEditing: () => editing,
              onQuitEditing: () => quits?.add('quitEditing'),
            ),
          ),
        ),
      );
      await settle(t);
      return submitted;
    }

    Future<void> open(WidgetTester t) async {
      await t.tap(find.bySemanticsLabel('workflow.nodes.llm.jsonSchema.import'));
      await settle(t);
    }

    Future<void> submit(WidgetTester t) async {
      await t.tap(find.text('common.operation.submit'));
      await settle(t);
    }

    Finder dialog() => find.byType(SchemaJsonEditor);

    testWidgets('measures the trigger width and opens the importer without quitting editing by default', (t) async {
      final quits = <String>[];
      await render(t, quits: quits);
      await open(t);
      expect(dialog(), findsOneWidget);
      expect(quits, isEmpty);
    });

    testWidgets('emits quitEditing when opening while advanced editing is active', (t) async {
      final quits = <String>[];
      await render(t, editing: true, quits: quits);
      await open(t);
      expect(quits, ['quitEditing']);
    });

    testWidgets('shows a parse error when the root value is not an object', (t) async {
      final submitted = await render(t);
      await open(t);
      await _typeJson(t, '[]');
      await submit(t);
      expect(find.text('Root must be an object, not an array or primitive value.'), findsOneWidget);
      expect(submitted, isEmpty);
    });

    testWidgets('shows a depth error when the schema exceeds the configured maximum', (t) async {
      final submitted = await render(t);
      await open(t);
      var deep = '1';
      for (var i = 0; i < 11; i++) {
        deep = '{"a":$deep}';
      }
      await _typeJson(t, deep);
      await submit(t);
      expect(find.text('Schema exceeds maximum depth of 10.'), findsOneWidget);
      expect(submitted, isEmpty);
    });

    testWidgets('shows the parser error when JSON.parse throws an Error', (t) async {
      final submitted = await render(t);
      await open(t);
      await _typeJson(t, '{"foo":');
      await submit(t);
      expect(find.byType(SchemaErrorMessage), findsOneWidget);
      expect(submitted, isEmpty);
    });

    testWidgets('submits valid JSON and closes the popover from footer actions', (t) async {
      final submitted = await render(t);
      await open(t);
      await _typeJson(t, '{"foo":"bar"}');
      await submit(t);
      expect(submitted, [
        {'foo': 'bar'},
      ]);
      expect(dialog(), findsNothing);
      await open(t);
      await t.tap(find.text('common.operation.cancel'));
      await settle(t);
      expect(dialog(), findsNothing);
    });
  });

  group('JsonSchemaConfig', () {
    Future<void> render(WidgetTester t) async {
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: SizedBox(
              width: 960,
              height: 800,
              child: JsonSchemaConfig(defaultSchema: defaultSchemaRoot(), onSave: (_) {}, onClose: () {}),
            ),
          ),
        ),
      );
      await settle(t);
    }

    bool selected(WidgetTester t, String tab) => t
        .widget<Semantics>(
          find.ancestor(
            of: find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == tab),
            matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.role == SemanticsRole.tab),
          ),
        )
        .properties
        .selected!;

    testWidgets('moves tab focus without activating a different editor', (t) async {
      await render(t);
      final visual = find.descendant(
        of: find.byType(SchemaViewTabs),
        matching: find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == 'Visual Editor'),
      );
      t.widget<DifyPressable>(visual).focusNode!.requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(t);
      final json = t.widget<DifyPressable>(
        find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == 'JSON Schema'),
      );
      expect(json.focusNode!.hasFocus, isTrue);
      expect(selected(t, 'Visual Editor'), isTrue);
      expect(find.byType(VisualEditor), findsOneWidget);
    });

    testWidgets('keeps the JSON editor active when its value cannot be validated', (t) async {
      await render(t);
      await t.tap(find.text('JSON Schema'));
      await settle(t);
      await enterCodeEditorText(t, 'invalid json', within: find.byType(SchemaJsonEditor));
      await settle(t, 200);
      await t.tap(find.text('Visual Editor'));
      await settle(t);
      expect(selected(t, 'JSON Schema'), isTrue);
      expect(find.byType(SchemaJsonEditor), findsOneWidget);
      expect(find.byType(SchemaErrorMessage), findsOneWidget);
    });
  });

  group('AdvancedActions', () {
    testWidgets('runs the matching actions from the buttons', (t) async {
      final calls = <String>[];
      await t.pumpWidget(
        _host(
          AdvancedActions(
            confirmDisabled: false,
            onCancel: () => calls.add('cancel'),
            onConfirm: () => calls.add('confirm'),
          ),
        ),
      );
      await t.tap(find.text('common.operation.cancel'));
      await t.tap(find.text('common.operation.confirm'));
      await settle(t);
      expect(calls, ['cancel', 'confirm']);
    });

    testWidgets('registers the confirm shortcut for input fields', (t) async {
      // The shortcut lives on the edit card around its inputs: Mod+Enter confirms while a field has the focus.
      final schema = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
        },
        'required': <String>[],
        'additionalProperties': false,
      };
      Map<String, Object?>? changed;
      final controller = SchemaEditorController(schemaOf: () => schema, onChange: (s) => changed = s)
        ..advancedEditing = true
        ..hoveringProperty = 'properties.name';
      await t.pumpWidget(
        _host(
          EditCard(
            fields: (name: 'name', type: 'string', required: false, description: null, enumValues: null),
            path: const ['properties', 'name'],
            parentPath: const [],
            depth: 1,
            controller: controller,
          ),
          width: 1500,
        ),
      );
      await t.tap(find.byType(EditableText).first);
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(t);
      expect(changed, isNotNull);
      expect(controller.advancedEditing, isFalse);
    });

    testWidgets('disables both confirmation paths when confirmation is unavailable', (t) async {
      await t.pumpWidget(_host(AdvancedActions(confirmDisabled: true, onCancel: () {}, onConfirm: () {})));
      final confirm = t.widget<DifyButton>(
        find.ancestor(of: find.text('common.operation.confirm'), matching: find.byType(DifyButton)),
      );
      expect(confirm.disabled, isTrue);
    });
  });

  group('TypeSelector', () {
    testWidgets('renders the check from Select item state and updates it after selection', (t) async {
      var current = 'string';
      const items = [(value: 'string', text: 'String'), (value: 'number', text: 'Number')];
      await t.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => SchemaTypeSelector(
              currentValue: current,
              items: items,
              onSelect: (item) => setState(() => current = item.value),
            ),
          ),
        ),
      );
      await t.tap(find.text('String'));
      await settle(t);
      Finder check(String label) => find.descendant(
        of: find.ancestor(of: find.text(label).last, matching: find.byType(DifyMenuItem)),
        matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == 'RemixIcon'),
      );
      expect(check('String'), findsOneWidget);
      expect(check('Number'), findsNothing);
      await t.tap(find.text('Number').last);
      await settle(t);
      await t.tap(find.text('Number'));
      await settle(t);
      expect(check('String'), findsNothing);
      expect(check('Number'), findsOneWidget);
    });
  });
}
