// Batch 4a follow-up: popovers of particular node bodies are pickers too, so on a phone they open as sheets and
// work there (knowledge retrieval's metadata filter, the tool picker, the model provider's credential dropdown, the
// LLM's JSON schema importer), at 411x914 with gesture insets.
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_added_card.dart' show DropdownContent;
import 'package:dify_sf_app/src/settings/model_provider/model_provider_env.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_metadata.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_json_schema.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/tool_picker.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/field.dart' show Field;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/dify_test_i18n.dart';
import '../dify_spec/workflow/nodes_panel/llm/model_fixtures.dart' show catalogOf, makeModel, makeModelItem, named;
import '../support/code_editor_input.dart';
import '../support/model_fakes.dart';
import 'phone_harness.dart' hide settle;

final _scrims = find.byKey(const ValueKey('dify-sheet-scrim'));

Future<void> _frames(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// [child] in a phone page, as a node panel's field would be.
Future<void> _pump(WidgetTester t, Widget child, {LlmGroupServices services = LlmGroupServices.empty}) async {
  phoneWindow(t);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      home: DifyPage(
        body: LlmGroupScope(
          services: services,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      ),
    ),
  );
  await _frames(t);
}

/// The sheet's top edge (its grab handle's) and that the sheet spans the window.
void _isSheet(WidgetTester t, String what) {
  expect(_scrims, findsWidgets, reason: '$what: the scrim');
  final handle = t.getRect(find.byType(DifySheetGrabHandle).last);
  expect(handle.width, 411, reason: '$what: a bottom sheet across the window');
  expect(t.testTextInput.isVisible, isFalse, reason: '$what: no keyboard');
}

void main() {
  setUp(useDifyTestTranslator);

  testWidgets('knowledge retrieval\'s metadata filter mode opens as a sheet and picks', (t) async {
    final picked = <String>[];
    await _pump(t, MetadataFilterSelector(value: 'disabled', onSelect: picked.add));
    await t.tap(find.text('workflow.nodes.knowledgeRetrieval.metadata.options.disabled.title'));
    await _frames(t);
    _isSheet(t, 'metadata filter');
    await t.tap(find.text('workflow.nodes.knowledgeRetrieval.metadata.options.manual.title'));
    await _frames(t);
    expect(picked, ['manual']);
    expect(_scrims, findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('the tool picker opens as a sheet, back closes it, and a tool is picked', (t) async {
    final picked = <PickedTool>[];
    await _pump(
      t,
      ToolPicker(
        trigger: (context, c) => DifyButton(onPressed: c.toggle, child: const DifyTextLine('Tools')),
        onSelect: picked.add,
        providers: const [
          {
            'id': 'time',
            'name': 'time',
            'type': 'builtin',
            'label': {'en_US': 'Time'},
            'tools': [
              {
                'name': 'current_time',
                'label': {'en_US': 'Current Time'},
              },
            ],
          },
        ],
      ),
    );
    await t.tap(find.text('Tools'));
    await _frames(t);
    _isSheet(t, 'tool picker');
    expect(await t.binding.handlePopRoute(), isTrue);
    await _frames(t);
    expect(_scrims, findsNothing, reason: 'back closed it');
    await t.tap(find.text('Tools'));
    await _frames(t);
    if (find.text('Current Time').evaluate().isEmpty) {
      await t.tap(find.text('Time'));
      await _frames(t);
    }
    await t.tap(find.text('Current Time'));
    await _frames(t);
    expect(picked.single.tool['name'], 'current_time');
    expect(_scrims, findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('the model provider\'s credential dropdown opens as a second sheet over the model list', (t) async {
    final provider = <String, Object?>{
      'provider': 'openai',
      'label': {'en_US': 'OpenAI'},
      'allow_custom_token': true,
      'supported_model_types': ['llm'],
      'configurate_methods': ['predefined-model'],
      'provider_credential_schema': {'credential_form_schemas': <Object?>[]},
      'custom_configuration': {
        'status': 'active',
        'current_credential_id': 'c1',
        'current_credential_name': 'Primary key',
        'current_credential_usable': true,
        'available_credentials': [
          {'credential_id': 'c1', 'credential_name': 'Primary key'},
          {'credential_id': 'c2', 'credential_name': 'Backup key'},
        ],
      },
    };
    final api = RecordingModelsApi()
      ..summaryData = [provider]
      ..providersData = [provider];
    final models = WorkspaceModels(api, fixedLanguage: 'en_US');
    addTearDown(models.dispose);
    await models.refreshSummary();
    await _pump(
      t,
      // In the LLM panel's "model" field, as on the device.
      Field(
        title: 'model',
        child: ModelSelector(value: null, models: [makeModel()]),
      ),
      services: LlmGroupServices(
        models: ModelCatalog(providers: models.providers),
        modelProviderEnv: ModelProviderEnv(
          models: models,
          permissionKeys: const ['credential.use', 'credential.create', 'credential.manage'],
        ),
      ),
    );
    await t.tap(named('plugin.detailPanel.configureModel'));
    await _frames(t);
    _isSheet(t, 'model list');
    expect(_scrims, findsOneWidget);
    // Touch rows: models 48 px; the provider row's credential control touch-high (a button in a sheet).
    expect(t.getSize(find.byType(ModelSelectorModelRow).first).height, 48);
    expect(t.getSize(named('Primary key')).height, greaterThanOrEqualTo(44));
    await t.tap(named('Primary key'));
    await _frames(t);
    expect(find.byType(DropdownContent), findsOneWidget);
    expect(find.text('Backup key'), findsOneWidget);
    expect(_scrims, findsNWidgets(2), reason: 'the credentials sheet over the model list sheet');
    // Its own title, not the label of the field the model selector is in.
    final headers = find.byType(DifySheetHeader);
    expect(
      find.descendant(of: headers.last, matching: find.text('common.modelProvider.auth.manageCredentials')),
      findsOneWidget,
    );
    expect(find.descendant(of: headers, matching: find.text('model')), findsNothing);
    expect(await t.binding.handlePopRoute(), isTrue);
    await _frames(t);
    expect(find.byType(DropdownContent), findsNothing);
    expect(_scrims, findsOneWidget, reason: 'back closed the credentials first');
    expect(t.takeException(), isNull);
  });

  testWidgets('the LLM\'s JSON schema importer opens as a sheet; its editor submits and closes it', (t) async {
    final submitted = <Object?>[];
    await _pump(
      t,
      Center(
        child: JsonImporter(onSubmit: submitted.add, isEditing: () => false),
      ),
    );
    await t.tap(find.bySemanticsLabel('workflow.nodes.llm.jsonSchema.import'));
    await _frames(t);
    _isSheet(t, 'JSON importer');
    expect(find.byType(SchemaJsonEditor), findsOneWidget);
    await enterCodeEditorText(t, '{"foo":"bar"}', within: find.byType(SchemaJsonEditor));
    await _frames(t, 3);
    await t.tap(find.text('common.operation.submit'));
    await _frames(t);
    expect(submitted, [
      {'foo': 'bar'},
    ]);
    expect(_scrims, findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('Model Settings as a sheet: one header, the sheets\' own (its title, a 44 px close), also in the "model" '
      'field', (t) async {
    await _pump(
      t,
      Field(
        title: 'model',
        child: ModelParameterModal(
          provider: 'openai',
          modelId: 'gpt-3.5-turbo',
          completionParams: const {'temperature': 0.7},
          onModelChange: (_) {},
          onCompletionParamsChange: (_) {},
        ),
      ),
      services: LlmGroupServices(
        models: catalogOf([
          makeModel(
            provider: 'openai',
            models: [
              makeModelItem(
                model: 'gpt-3.5-turbo',
                label: const {'en_US': 'GPT-3.5'},
                modelProperties: const {'mode': 'chat'},
              ),
            ],
          ),
        ]),
        parameterRules: (p, m) => Future.value(const <Map<String, Object?>>[]),
      ),
    );
    await t.tap(named('common.modelProvider.modelSettings'));
    await _frames(t);
    _isSheet(t, 'model settings');
    final header = find.byType(DifySheetHeader);
    expect(header, findsOneWidget, reason: 'one header (not the field\'s label over the sheet\'s own)');
    expect(find.descendant(of: header, matching: find.text('common.modelProvider.modelSettings')), findsOneWidget);
    final close = find.descendant(of: header, matching: find.byType(DifyTouchIconButton));
    expect(t.getSize(close).height, 44);
    await t.tap(close);
    await _frames(t);
    expect(_scrims, findsNothing);
    expect(t.takeException(), isNull);
  });
}
