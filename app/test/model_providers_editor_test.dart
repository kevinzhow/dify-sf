/// The editor's model services built from the workspace's model providers (phase C): the model catalog, default
/// models and parameter rules handed to the model-node panels, the providers handed to the features panel and the
/// checklist ("Configure a model" only for providers the workspace does not have), the icons, and the refresh when a
/// model selector opens.
library;

import 'package:dify_sf_app/src/cards/provider_icon_image.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart' show nodeFromDify;
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/features/workflow_features.dart';
import 'package:dify_sf_app/src/workflow_editor/header/workflow_header.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';
import 'support/model_fakes.dart';

Future<void> _settle(WidgetTester t, [int steps = 20]) async {
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

late RecordingModelsApi api;
late WorkspaceModels models;
var settingsOpened = 0;

Future<DemoBackend> _open(WidgetTester t) async {
  await useAppFonts();
  t.view.physicalSize = const Size(1600, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  api = RecordingModelsApi()
    ..summaryData = [summaryJson(provider: 'langgenius/openai/openai')]
    ..providersData = [
      providerJson(customConfiguration: const {'status': 'active'}),
    ]
    ..modelsByType['llm'] = [
      providerWithModels('langgenius/openai/openai', ['gpt-4']),
    ]
    ..defaults['llm'] = defaultModelJson('langgenius/openai/openai', 'gpt-4')
    ..rules['langgenius/openai/openai/gpt-4'] = [
      {'name': 'temperature', 'type': 'float'},
    ];
  models = WorkspaceModels(api, fixedLanguage: 'en_US');
  settingsOpened = 0;
  final demo = DemoBackend(withBo: false);
  await t.pumpWidget(
    MaterialApp(
      home: EditorPage(
        backend: demo,
        docId: 'demo',
        clientId: 'me-abc123',
        journaled: false,
        models: models,
        openModelProviderSettings: (_) async => settingsOpened++,
      ),
    ),
  );
  await _settle(t);
  return demo;
}

Future<void> _close(WidgetTester t, DemoBackend demo) async {
  await t.pumpWidget(const SizedBox());
  await demo.dispose();
  await t.pump(const Duration(seconds: 20));
}

LlmGroupServices _services(WidgetTester t) => LlmGroupScope.of(t.element(find.byType(WorkflowHeader)));

Map<String, Object?> _llm(String id, String provider) => {
  'id': id,
  'type': 'custom',
  'position': {'x': 400, 'y': 300},
  'data': {
    'type': 'llm',
    'title': 'LLM $id',
    'model': {'provider': provider, 'name': 'gpt-4', 'mode': 'chat', 'completion_params': <String, Object?>{}},
    'prompt_template': [
      {'role': 'system', 'text': 'hi'},
    ],
    'context': {'enabled': false, 'variable_selector': <Object?>[]},
    'vision': {'enabled': false},
  },
};

List<String> _configureModelNodes(WidgetTester t) {
  final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowHeader)));
  return [
    for (final i in store.checklistItems.value)
      if ((i['errorMessages'] as List? ?? const []).any((m) => '$m'.contains('configureModel'))) '${i['id']}',
  ];
}

void main() {
  testWidgets('loads the providers, every model list and the default models when the editor opens', (t) async {
    final demo = await _open(t);
    expect(api.callsOf('summaries'), isNotEmpty);
    expect(
      {for (final c in api.callsOf('modelsOfType')) c['modelType']},
      {'llm', 'text-embedding', 'rerank', 'speech2text', 'moderation', 'tts'},
    );
    expect(
      {for (final c in api.callsOf('defaultModel')) c['modelType']},
      {
        'llm',
        'text-embedding',
        'rerank',
        'speech2text',
        'tts',
      },
    );
    await _close(t, demo);
  });

  testWidgets('hands the catalog, the default models and the parameter rules to the model-node panels', (t) async {
    final demo = await _open(t);
    final s = _services(t);
    expect([for (final p in s.models.providers) p.provider], ['langgenius/openai/openai']);
    expect(s.models.textGenerationModelList.single.models.single.model, 'gpt-4');
    expect(s.defaultModels['llm'], (provider: 'langgenius/openai/openai', model: 'gpt-4', mode: 'chat'));
    expect(await s.parameterRules!('langgenius/openai/openai', 'gpt-4'), [
      {'name': 'temperature', 'type': 'float'},
    ]);
    s.openModelProviderSettings!();
    expect(settingsOpened, 1);
    // The icons come through the API (relative URLs).
    final icons = ProviderIconScope.of(t.element(find.byType(WorkflowHeader)));
    expect(identical(icons, models.icons), isTrue);
    await _close(t, demo);
  });

  testWidgets('refetches the providers and model lists when a model selector opens', (t) async {
    final demo = await _open(t);
    api.calls.clear();
    // The refresh is throttled: wait it out first.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 6)));
    _services(t).refreshModels!();
    await _settle(t, 5);
    expect(api.callsOf('summaries'), hasLength(1));
    expect(api.callsOf('modelsOfType'), hasLength(6));
    await _close(t, demo);
  });

  testWidgets('hands the providers to the features panel (OpenAI moderation)', (t) async {
    final demo = await _open(t);
    await models.loadProviderDetails();
    await _settle(t, 3);
    final features = t.widget<WorkflowFeatures>(find.byType(WorkflowFeatures));
    expect(features.services.modelProviders, api.providersData);
    expect(features.services.isOpenAIProviderConfigured, isTrue);
    features.services.openAccountSettings!('provider');
    expect(settingsOpened, 1);
    await _close(t, demo);
  });

  testWidgets('the checklist asks to configure a model only for providers the workspace does not have', (t) async {
    final demo = await _open(t);
    final controller = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
    final doc = controller.doc;
    controller.addNodes([
      nodeFromDify(_llm('known', 'langgenius/openai/openai'), doc, id: 'known'),
      nodeFromDify(_llm('unknown', 'langgenius/acme/acme'), doc, id: 'unknown'),
    ]);
    await _settle(t, 5);
    expect(_configureModelNodes(t), contains('unknown'));
    expect(_configureModelNodes(t), isNot(contains('known')));
    await _close(t, demo);
  });
}
