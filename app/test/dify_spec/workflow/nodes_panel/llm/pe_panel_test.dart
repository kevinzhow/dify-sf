// dify-spec: web/app/components/workflow/nodes/parameter-extractor/components/extract-parameter/__tests__/import-from-tool.spec.tsx
// dify-spec: web/app/components/workflow/nodes/parameter-extractor/components/extract-parameter/__tests__/item.spec.tsx
// dify-spec: web/app/components/workflow/nodes/parameter-extractor/components/extract-parameter/__tests__/update.spec.tsx
// dify-spec: web/app/components/workflow/nodes/parameter-extractor/components/__tests__/reasoning-mode-picker.spec.tsx
// dify-spec: web/app/components/workflow/nodes/parameter-extractor/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/parameter-extractor/__tests__/integration.spec.tsx
//
// The Parameter Extractor's panel over a document in an in-memory session, and its components alone. Where Dify
// mocks a child (the prompt editor, memory config, the model modal, config-select), the cases drive the real one
// through its callbacks and read the node's data. The tool picker is dify-sf's minimal Tools panel over the store's
// tool lists (Dify's block selector in its standalone Tools mode).
import 'package:dify_sf_app/src/cards/bodies/llm_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/pe_params.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/field_hints.dart';
import 'harness.dart';
import 'qc_pe_test_kit.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

Map<String, Object?> param({
  String name = 'city',
  String type = 'string',
  String description = 'City name',
  bool required = false,
  List<String>? options,
}) => {'name': name, 'type': type, 'description': description, 'required': required, 'options': ?options};

Map<String, Object?> peData([Map<String, Object?> overrides = const {}]) => {
  'model': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat', 'completion_params': <String, Object?>{}},
  'query': ['start', 'query'],
  'reasoning_mode': 'prompt',
  'parameters': [param()],
  'instruction': 'Extract city and budget',
  'vision': {'enabled': false},
  ...overrides,
};

const _models = ModelCatalog(
  providers: [
    ModelProvider(provider: 'openai', label: {'en_US': 'OpenAI'}),
  ],
  modelLists: {
    ModelTypeEnum.textGeneration: [
      ProviderWithModels(
        provider: 'openai',
        label: {'en_US': 'OpenAI'},
        models: [
          ModelItem(
            model: 'gpt-4o',
            label: {'en_US': 'gpt-4o'},
            features: [ModelFeatureEnum.vision, ModelFeatureEnum.toolCall],
          ),
        ],
      ),
    ],
  },
);

Map<String, Object?> toolParameter({
  String name = 'field',
  String form = 'llm',
  String description = 'Field description',
  bool required = false,
  List<Object?>? options,
}) => {
  'name': name,
  'label': {'en_US': name},
  'type': 'string',
  'form': form,
  'llm_description': description,
  'required': required,
  'options': ?options,
};

Map<String, Object?> toolProvider(String type, String id, String toolName, String toolLabel, List<Object?> params) => {
  'id': id,
  'name': 'provider-one',
  'label': {'en_US': 'Provider One'},
  'type': type,
  'icon': 'icon',
  'tools': [
    {
      'name': toolName,
      'label': {'en_US': toolLabel},
      'description': {'en_US': '$toolLabel description'},
      'parameters': params,
    },
  ],
};

Finder _add() => find.bySemanticsLabel('workflow.nodes.parameterExtractor.addExtractParameter');
Finder _input(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is DifyInput && w.semanticLabel == label),
  matching: find.byType(EditableText),
);
Finder _nameInput() => _input('workflow.nodes.parameterExtractor.addExtractParameterContent.name');
Finder _descInput() => find.descendant(
  of: find.byWidgetPredicate(
    (w) =>
        w is TextField &&
        hintTextOf(w) == 'workflow.nodes.parameterExtractor.addExtractParameterContent.descriptionPlaceholder',
  ),
  matching: find.byType(EditableText),
);
String _text(WidgetTester t, Finder f) => t.widget<EditableText>(f).controller.text;

/// Opens the edit dialog of [payload] from a button (Dify renders type="edit" open at once).
Widget _editLauncher(Map<String, Object?> payload, void Function(Map<String, Object?>, ParamRename?) onSave) => Builder(
  builder: (context) => TextButton(
    onPressed: () => showExtractParameterDialog(context, isAdd: false, payload: payload, onSave: onSave),
    child: const Text('open-edit'),
  ),
);

Future<void> _openEdit(
  WidgetTester t,
  Map<String, Object?> payload,
  void Function(Map<String, Object?>, ParamRename?) onSave, {
  Toasts? toasts,
}) async {
  await pumpComponent(t, _editLauncher(payload, onSave), services: LlmGroupServices(toast: toasts?.call));
  await t.tap(find.text('open-edit'));
  await settleShort(t);
}

void main() {
  setUp(useShortVisionTranslator);

  Future<Harness> renderPanel(
    WidgetTester t, {
    Map<String, Object?> data = const {},
    LlmGroupServices services = const LlmGroupServices(models: _models),
  }) => startPanel(
    t,
    [
      ('start', 'start', {'variables': <Object?>[]}),
      ('pe', 'parameter-extractor', peData(data)),
    ],
    services: services,
    chatMode: true,
  );

  Map<String, Object?> pe(Harness h) => dataOf(h, 'pe');

  group('parameter-extractor/extract-parameter/import-from-tool', () {
    Future<List<List<Map<String, Object?>>>> render(WidgetTester t, WorkflowStore store) async {
      final imports = <List<Map<String, Object?>>>[];
      await pumpComponent(t, ImportFromTool(onImport: imports.add), store: store);
      await t.tap(find.text('import'));
      await settleShort(t);
      return imports;
    }

    testWidgets('imports llm parameters from a built-in tool through the real block selector', (t) async {
      final store = WorkflowStore()
        ..buildInTools.value = [
          toolProvider('builtin', 'provider-1', 'search', 'Search Tool', [
            toolParameter(
              name: 'city',
              required: true,
              description: 'City name',
              options: [
                {
                  'value': 'draft',
                  'label': {'en_US': 'Draft'},
                },
              ],
            ),
            toolParameter(name: 'internal_only', form: 'form', description: 'Should be ignored'),
          ]),
        ];
      final imports = await render(t, store);
      await t.tap(find.text('Provider One'));
      await settleShort(t);
      await t.tap(find.text('Search Tool'));
      await settleShort(t);
      expect(imports.single, [
        {
          'name': 'city',
          'type': 'string',
          'required': true,
          'description': 'City name',
          'options': ['Draft'],
        },
      ]);
    });

    testWidgets('imports llm parameters from \$collectionType tool collections', (t) async {
      for (final (type, label, name, description) in const [
        ('api', 'Custom Tool', 'record_id', 'Record identifier'),
        ('workflow', 'Workflow Tool', 'summary', 'Summary text'),
      ]) {
        final store = WorkflowStore();
        final provider = toolProvider(type, '$type-1', 'tool', label, [
          toolParameter(name: name, description: description),
        ]);
        if (type == 'api') {
          store.customTools.value = [provider];
        } else {
          store.workflowTools.value = [provider];
        }
        final imports = await render(t, store);
        if (type == 'api') {
          await t.ensureVisible(find.text('workflow.tabs.customTool'));
          await t.tap(find.text('workflow.tabs.customTool'));
          await settleShort(t);
          await t.tap(find.text('Provider One'));
          await settleShort(t);
        }
        await t.tap(find.text(label));
        await settleShort(t);
        expect(imports.single, [
          {'name': name, 'type': 'string', 'required': false, 'description': description, 'options': <Object?>[]},
        ]);
      }
    });
  });

  group('parameter-extractor/extract-parameter/item', () {
    testWidgets('renders parameter details and forwards edit and delete actions', (t) async {
      var edits = 0, deletes = 0;
      await pumpComponent(
        t,
        ExtractParamItem(
          payload: param(required: true),
          onEdit: () => edits++,
          onDelete: () => deletes++,
        ),
      );
      expect(find.text('city'), findsOneWidget);
      expect(find.text('String'), findsOneWidget); // CSS capitalize
      expect(find.text('City name'), findsOneWidget);
      expect(find.text('WORKFLOW.NODES.PARAMETEREXTRACTOR.ADDEXTRACTPARAMETERCONTENT.REQUIRED'), findsOneWidget);
      await t.tap(find.text('city'));
      await t.pump();
      await t.tap(find.bySemanticsLabel('common.operation.edit'));
      await t.tap(find.bySemanticsLabel('common.operation.delete'));
      expect(edits, 1);
      expect(deletes, 1);
    });
  });

  group('parameter-extractor/extract-parameter/update', () {
    testWidgets('opens from the add trigger and saves a new parameter', (t) async {
      final saves = <(Map<String, Object?>, ParamRename?)>[];
      await pumpComponent(t, AddExtractParameterButton(onSave: (p, r) => saves.add((p, r))));
      expect(find.bySemanticsLabel('workflow.nodes.parameterExtractor.addExtractParameter'), findsOneWidget);
      await t.tap(_add());
      await settleShort(t);
      await t.enterText(_nameInput(), 'budget');
      await t.enterText(_descInput(), 'Budget amount');
      await t.pump();
      expect(_text(t, _nameInput()), 'budget');
      expect(_text(t, _descInput()), 'Budget amount');
      await t.tap(find.text('common.operation.add'));
      await settleShort(t);
      expect(saves.single.$1, {'name': 'budget', 'type': 'string', 'description': 'Budget amount', 'required': false});
      expect(saves.single.$2, isNull);
    });

    testWidgets('rejects invalid variable names before saving', (t) async {
      final toasts = Toasts();
      final saves = [];
      await pumpComponent(
        t,
        AddExtractParameterButton(onSave: (p, r) => saves.add(p)),
        services: LlmGroupServices(toast: toasts.call),
      );
      await t.tap(_add());
      await settleShort(t);
      await t.enterText(_nameInput(), '1bad');
      await t.pump();
      expect(saves, isEmpty);
      expect(toasts.messages, isNotEmpty);
      expect(_text(t, _nameInput()), '');
    });

    testWidgets('renders the edit modal immediately and validates required fields', (t) async {
      final toasts = Toasts();
      final saves = [];
      await _openEdit(
        t,
        param(name: '', description: ''),
        (p, r) => saves.add(p),
        toasts: toasts,
      );
      await t.tap(find.text('common.operation.save'));
      await t.pump();
      expect(saves, isEmpty);
      expect(toasts.messages, isNotEmpty);
    });

    testWidgets('requires options before saving a select parameter', (t) async {
      final toasts = Toasts();
      final saves = [];
      await _openEdit(
        t,
        param(type: 'select', description: 'Status description', options: []),
        (p, r) => saves.add(p),
        toasts: toasts,
      );
      await t.tap(find.text('common.operation.save'));
      await t.pump();
      expect(saves, isEmpty);
      expect(toasts.messages.single, contains('app-debug.variableConfig.options'));
    });
  });

  group('parameter-extractor/reasoning-mode-picker', () {
    testWidgets('switches between prompt and function call reasoning modes', (t) async {
      final changes = <String>[];
      Widget picker(String type) => ReasoningModePicker(type: type, onChange: changes.add);
      await pumpComponent(t, picker('prompt'));
      await t.tap(find.text('fnCall'));
      await pumpComponent(t, picker('function_call'));
      await t.tap(find.text('prompt'));
      expect(changes, ['function_call', 'prompt']);
    });
  });

  group('parameter-extractor/panel', () {
    testWidgets('wires model, parameter, instruction, memory, and reasoning actions to use-config', (t) async {
      final h = await renderPanel(t);
      t.widget<ModelParameterModal>(find.byType(ModelParameterModal)).onModelChange((
        provider: 'openai',
        modelId: 'gpt-4o',
        mode: 'chat',
        features: const [],
      ));
      await settle(t);
      t.widget<ModelParameterModal>(find.byType(ModelParameterModal)).onCompletionParamsChange({'temperature': 0.2});
      await settle(t);
      t.widget<VarReferencePicker>(find.byType(VarReferencePicker).first).onChange(['start', 'query2'], null);
      await settle(t);
      await t.tap(find.bySemanticsLabel('workflow.nodes.llm.vision'));
      await settle(t);
      t.widget<ConfigVision>(find.byType(ConfigVision)).onConfigChange({
        'detail': 'high',
        'variable_selector': <String>[],
      });
      await settle(t);
      t.widget<ImportFromTool>(find.byType(ImportFromTool)).onImport([param(name: 'budget')]);
      await settle(t);
      t.widget<AddExtractParameterButton>(find.byType(AddExtractParameterButton)).onSave(param(), null);
      await settle(t);
      editors(t).last.onChange('Updated instruction');
      await settle(t);
      // Advanced Setting is closed at first.
      await t.tap(find.text('WORKFLOW.NODES.PARAMETEREXTRACTOR.ADVANCEDSETTING', findRichText: true));
      await settle(t);
      await t.tap(find.bySemanticsLabel('workflow.nodes.common.memory.memory'));
      await settle(t);
      await t.tap(find.text('fnCall'));
      await settle(t);

      final d = pe(h);
      expect(d['model'], {
        'provider': 'openai',
        'name': 'gpt-4o',
        'mode': 'chat',
        'completion_params': {'temperature': 0.2},
      });
      expect(d['query'], ['start', 'query2']);
      expect(d['vision'], {
        'enabled': true,
        'configs': {'detail': 'high', 'variable_selector': <String>[]},
      });
      expect(d['parameters'], [param(name: 'budget'), param()]);
      expect(d['instruction'], 'Updated instruction');
      expect((d['memory']! as Map)['role_prefix'], {'user': '', 'assistant': ''});
      expect(d['reasoning_mode'], 'function_call');
      await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
      await settle(t);
      for (final s in ['budget', 'city', '__is_success', '__reason', '__usage']) {
        expect(find.text(s), findsWidgets);
      }
      await h.dispose(t);
    });
  });

  group('parameter-extractor path', () {
    group('Tool import and parameter editing', () {
      testWidgets('should show the empty state for an empty parameter list', (t) async {
        await pumpComponent(t, ExtractParamList(list: const [], onChange: (_, _) {}));
        expect(find.text('workflow.nodes.parameterExtractor.extractParametersNotSet'), findsOneWidget);
      });

      testWidgets('should edit and delete parameters from the list', (t) async {
        final changes = <(List<Map<String, Object?>>, ParamRename?)>[];
        await pumpComponent(t, ExtractParamList(list: [param()], onChange: (l, r) => changes.add((l, r))));
        await t.tap(find.text('city'));
        await t.pump();
        await t.tap(find.bySemanticsLabel('common.operation.edit'));
        await settleShort(t);
        await t.enterText(_nameInput(), 'city_name');
        await t.enterText(_descInput(), 'Updated city description');
        await t.tap(find.text('common.operation.save'));
        await settleShort(t);
        expect(changes.single.$1, [param(name: 'city_name', description: 'Updated city description')]);
        expect(changes.single.$2, isNull);

        changes.clear();
        await pumpComponent(
          t,
          ExtractParamList(
            list: [param(name: 'budget')],
            onChange: (l, r) => changes.add((l, r)),
          ),
        );
        await t.tap(find.text('budget'));
        await t.pump();
        await t.tap(find.bySemanticsLabel('common.operation.delete'));
        expect(changes.single.$1, isEmpty);
      });

      testWidgets('should validate required fields before saving an incomplete parameter', (t) async {
        final toasts = Toasts();
        final saves = [];
        await _openEdit(
          t,
          param(name: '', description: ''),
          (p, r) => saves.add(p),
          toasts: toasts,
        );
        await t.tap(find.text('common.operation.save'));
        await t.pump();
        expect(saves, isEmpty);
        expect(toasts.messages, isNotEmpty);
      });

      testWidgets('should render the add trigger for new parameters', (t) async {
        await pumpComponent(t, AddExtractParameterButton(onSave: (_, _) {}));
        expect(_add(), findsOneWidget);
      });

      testWidgets('should reject invalid names and reset add modal fields after canceling', (t) async {
        final toasts = Toasts();
        var cancels = 0;
        await pumpComponent(
          t,
          AddExtractParameterButton(onSave: (_, _) {}, onCancel: () => cancels++),
          services: LlmGroupServices(toast: toasts.call),
        );
        await t.tap(_add());
        await settleShort(t);
        await t.enterText(_nameInput(), '1bad');
        await t.pump();
        expect(toasts.messages, isNotEmpty);
        expect(_text(t, _nameInput()), '');
        await t.enterText(_nameInput(), 'temporary_name');
        await t.enterText(_descInput(), 'Temporary description');
        await t.tap(find.text('common.operation.cancel'));
        await settleShort(t);
        expect(cancels, 1);
        expect(_nameInput(), findsNothing);
        await t.tap(_add());
        await settleShort(t);
        expect(_text(t, _nameInput()), '');
        expect(_text(t, _descInput()), '');
      });

      testWidgets('should require select options before saving a select parameter', (t) async {
        final toasts = Toasts();
        final saves = [];
        await _openEdit(
          t,
          param(name: 'status', type: 'select', description: 'Status field', options: []),
          (p, r) => saves.add(p),
          toasts: toasts,
        );
        await t.tap(find.text('common.operation.save'));
        await t.pump();
        expect(saves, isEmpty);
        expect(toasts.messages, isNotEmpty);
      });

      testWidgets('should keep rename metadata and updated options when editing a select parameter', (t) async {
        final saves = <(Map<String, Object?>, ParamRename?)>[];
        await _openEdit(
          t,
          param(name: 'status', type: 'select', description: 'Status', options: ['draft']),
          (p, r) => saves.add((p, r)),
        );
        await t.enterText(_nameInput(), 'approval_status');
        await t.tap(find.text('app-debug.variableConfig.addOption'));
        await t.pump();
        await t.enterText(
          find.descendant(
            of: find.bySemanticsLabel('app-debug.variableConfig.options 2'),
            matching: find.byType(EditableText),
          ),
          'published',
        );
        await t.tap(find.text('common.operation.save'));
        await settleShort(t);
        expect(saves.single.$1, {
          'name': 'approval_status',
          'type': 'select',
          'description': 'Status',
          'options': ['draft', 'published'],
          'required': false,
        });
        expect(saves.single.$2, isNull);
      });

      testWidgets('should persist rename metadata and required state for edited parameters', (t) async {
        final saves = <(Map<String, Object?>, ParamRename?)>[];
        await _openEdit(t, param(name: 'status', description: 'Status description'), (p, r) => saves.add((p, r)));
        await t.enterText(_nameInput(), 'approval_status');
        await t.tap(find.byType(DifySwitch).last);
        await t.tap(find.text('common.operation.save'));
        await settleShort(t);
        expect(saves.single.$1, {
          'name': 'approval_status',
          'type': 'string',
          'description': 'Status description',
          'required': true,
        });
        expect(saves.single.$2, isNull);
      });
    });

    group('Node and panel integration', () {
      testWidgets('should let users switch the reasoning mode', (t) async {
        final changes = <String>[];
        var type = 'prompt';
        await pumpComponent(
          t,
          StatefulBuilder(
            builder: (context, setState) => ReasoningModePicker(
              type: type,
              onChange: (v) {
                changes.add(v);
                setState(() => type = v);
              },
            ),
          ),
        );
        await t.tap(find.text('fnCall'));
        await t.pump();
        await t.tap(find.text('prompt'));
        expect(changes, ['function_call', 'prompt']);
      });

      testWidgets('should render the selected model on the node only when configured', (t) async {
        Future<void> card(Map<String, Value> model) async {
          final ctx = BodyContext(
            Node(id: 'parameter-node', type: 'parameter-extractor', title: 'PE', config: {'model': VMap(model)}),
            (_) => null,
            models: const ModelCatalog(
              modelLists: {
                ModelTypeEnum.textGeneration: [
                  ProviderWithModels(
                    provider: 'openai',
                    models: [ModelItem(model: 'gpt-4o')],
                  ),
                ],
              },
            ),
          );
          await t.pumpWidget(
            MaterialApp(
              home: Material(
                child: SizedBox(
                  width: 238,
                  child: Builder(builder: (c) => const ParameterExtractorBody().build(c, ctx)),
                ),
              ),
            ),
          );
        }

        await card({'provider': const VString('openai'), 'name': const VString('gpt-4o')});
        final chip = t.widget<ModelChip>(find.byType(ModelChip));
        expect('${chip.value!.provider}:${chip.value!.model}', 'openai:gpt-4o');
        await card({'provider': const VString(''), 'name': const VString('')});
        expect(find.byType(ModelChip), findsNothing);
      });

      testWidgets('should wire panel actions across model, input, import, vision, memory, and outputs', (t) async {
        final h = await renderPanel(
          t,
          data: {
            'parameters': [param(), param(name: 'budget', type: 'number')],
          },
        );
        h.store.buildInTools.value = [
          toolProvider('builtin', 'provider-1', 'search', 'Search Tool', [
            toolParameter(
              name: 'city',
              required: true,
              description: 'City name',
              options: [
                {
                  'value': 'draft',
                  'label': {'en_US': 'Draft'},
                },
              ],
            ),
          ]),
        ];
        t.widget<ModelParameterModal>(find.byType(ModelParameterModal)).onModelChange((
          provider: 'anthropic',
          modelId: 'claude-3-7-sonnet',
          mode: 'chat',
          features: const [],
        ));
        await settle(t);
        await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
        await settle(t);
        expect(find.text('budget'), findsWidgets);
        expect(find.text('__usage'), findsOneWidget);
        await t.tap(find.text('import'));
        await settle(t);
        await t.tap(find.text('Provider One'));
        await settle(t);
        await t.tap(find.text('Search Tool'));
        await settle(t);
        final d = pe(h);
        expect(d['model'], containsPair('provider', 'anthropic'));
        expect(d['parameters'], [
          {
            'name': 'city',
            'type': 'string',
            'required': true,
            'description': 'City name',
            'options': ['Draft'],
          },
        ]);
        await h.dispose(t);
      });
    });
  });

  group('dify-sf behaviour', () {
    testWidgets('renaming a parameter rewrites the references of downstream nodes', (t) async {
      final h = await startPanel(
        t,
        [
          ('start', 'start', {'variables': <Object?>[]}),
          ('pe', 'parameter-extractor', peData()),
          (
            'end',
            'end',
            {
              'outputs': [
                {
                  'variable': 'x',
                  'value_selector': ['pe', 'city'],
                },
              ],
            },
          ),
        ],
        services: const LlmGroupServices(models: _models),
        pump: false,
      );
      await t.pumpWidget(llmPanel(h, 'pe', services: const LlmGroupServices(models: _models)));
      await settle(t);
      await t.tap(find.text('city'));
      await t.pump();
      await t.tap(find.bySemanticsLabel('common.operation.edit'));
      await settle(t);
      await t.enterText(_nameInput(), 'city_name');
      await t.tap(find.text('common.operation.save'));
      await settle(t);
      expect((dataOf(h, 'pe')['parameters']! as List).single, containsPair('name', 'city_name'));
      expect(((dataOf(h, 'end')['outputs']! as List).single as Map)['value_selector'], ['pe', 'city_name']);
      await h.dispose(t);
    });
  });
}
