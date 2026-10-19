// dify-spec: web/app/components/header/account-setting/model-provider-page/system-model-selector/__tests__/index.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/model_provider/system_model_selector.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_selector.dart' show ModelSelector;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

const types = ['llm', 'text-embedding', 'rerank', 'speech2text', 'tts'];

late RecordingModelsApi api;
late WorkspaceModels models;

/// The page passes the default models; here the store has the LLM default (gpt-4 of OpenAI).
Future<void> render(
  WidgetTester t, {
  bool isLoading = false,
  bool hideProviderSettingsFooter = false,
  List<String> permissionKeys = const ['plugin.model_config'],
  bool withModels = true,
}) async {
  api = RecordingModelsApi();
  if (withModels) {
    for (final type in types) {
      api.modelsByType[type] = [
        providerWithModels('openai', ['$type-model'], modelType: type),
      ];
    }
    api.modelsByType['llm'] = [
      providerWithModels('openai', ['gpt-4', 'test']),
    ];
  }
  api.defaults['llm'] = defaultModelJson('openai', 'gpt-4');
  api.summaryData = [summaryJson(provider: 'openai')];
  models = WorkspaceModels(api, fixedLanguage: 'en_US');
  await models.refreshSummary();
  await models.updateModelList('llm');
  await models.invalidateDefaultModel('llm');
  api.calls.clear();
  await renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: SystemModelSelector(
          notConfigured: false,
          isLoading: isLoading,
          hideProviderSettingsFooter: hideProviderSettingsFooter,
        ),
      ),
    ),
    env: envOf(api, permissionKeys: permissionKeys, models: models),
    translator: _Translations(),
  );
}

/// The spec's i18n mock: these keys in English, the others as `<ns>.<key>`.
class _Translations implements Translator {
  static const _common = {
    'modelProvider.systemModelSettings': 'System Model Settings',
    'modelProvider.systemModelSettingsDesc': 'Set default models.',
    'modelProvider.systemModelSettingsTitle': 'Default Model Settings',
    'modelProvider.systemReasoningModel.key': 'System Reasoning Model',
    'modelProvider.systemReasoningModel.tip': 'Reasoning model tip',
    'modelProvider.embeddingModel.key': 'Embedding Model',
    'modelProvider.embeddingModel.tip': 'Embedding model tip',
    'modelProvider.rerankModel.key': 'Rerank Model',
    'modelProvider.rerankModel.tip': 'Rerank model tip',
    'modelProvider.speechToTextModel.key': 'Speech to Text Model',
    'modelProvider.speechToTextModel.tip': 'Speech to text model tip',
    'modelProvider.ttsModel.key': 'TTS Model',
    'modelProvider.ttsModel.tip': 'TTS model tip',
    'operation.cancel': 'Cancel',
    'operation.save': 'Save',
    'loading': 'Loading',
    'actionMsg.modifiedSuccessfully': 'Modified successfully',
  };

  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      (ns == 'common' ? _common[key] : null) ?? '$ns.$key';
}

Finder get settingsButton => find.byKey(const ValueKey('system-model-selector-button'));
Finder get saveButton => find.byKey(const ValueKey('system-model-save'));
Finder get cancelButton => find.byKey(const ValueKey('system-model-cancel'));
bool saveEnabled(WidgetTester t) => !t.widget<DifyButton>(saveButton).disabled;

Future<void> openDialog(WidgetTester t) async {
  await t.tap(settingsButton);
  await settle(t);
}

void main() {
  group('SystemModel', () {
    testWidgets('should render settings button', (t) async {
      await render(t);
      expect(find.text('System Model Settings'), findsOneWidget);
    });

    testWidgets('should open dialog when button is clicked', (t) async {
      await render(t);
      await openDialog(t);
      expect(find.text('System Reasoning Model'), findsOneWidget);
    });

    testWidgets('loads non-text model lists only after the dialog opens', (t) async {
      await render(t);
      expect(api.callsOf('modelsOfType'), isEmpty);
      await openDialog(t);
      expect(
        [for (final c in api.callsOf('modelsOfType')) c['modelType']],
        containsAll(['text-embedding', 'rerank', 'speech2text', 'tts']),
      );
    });

    testWidgets('shows loading instead of empty model selectors while model lists load', (t) async {
      await render(t, withModels: false);
      final gate = api.hold['modelsOfType'] = Completer();
      models = WorkspaceModels(api, fixedLanguage: 'en_US');
      await render(t, withModels: false);
      api.hold['modelsOfType'] = gate;
      await openDialog(t);
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
      expect(find.byType(ModelSelector), findsNothing);
      expect(saveEnabled(t), isFalse);
      await t.tap(saveButton);
      await settle(t);
      expect(api.callsOf('setDefaultModels'), isEmpty);
      gate.complete();
      await settle(t);
    });

    testWidgets('should disable button when loading', (t) async {
      await render(t, isLoading: true);
      expect(t.widget<DifyButton>(settingsButton).disabled, isTrue);
    });

    testWidgets('should close dialog when cancel is clicked', (t) async {
      await render(t);
      await openDialog(t);
      expect(cancelButton, findsOneWidget);
      await t.tap(cancelButton);
      await settle(t);
      expect(cancelButton, findsNothing);
    });

    testWidgets('should save selected models and show success feedback', (t) async {
      await render(t);
      await openDialog(t);
      for (final (i, type) in types.indexed) {
        await t.tap(find.byType(ModelSelector).at(i));
        await settle(t);
        await t.tap(find.text(i == 0 ? 'test' : '$type-model').last);
        await settle(t);
      }
      api.calls.clear();
      await t.tap(saveButton);
      await settle(t);
      expect(api.callsOf('setDefaultModels'), [
        {
          'settings': [
            {'model_type': 'llm', 'provider': 'openai', 'model': 'test'},
            {'model_type': 'text-embedding', 'provider': 'openai', 'model': 'text-embedding-model'},
            {'model_type': 'rerank', 'provider': 'openai', 'model': 'rerank-model'},
            {'model_type': 'speech2text', 'provider': 'openai', 'model': 'speech2text-model'},
            {'model_type': 'tts', 'provider': 'openai', 'model': 'tts-model'},
          ],
        },
      ]);
      expect(find.text('Modified successfully'), findsOneWidget);
      expect(api.callsOf('defaultModel'), hasLength(5));
      expect(api.callsOf('modelsOfType'), hasLength(5));
    });

    testWidgets('should keep the dialog open when saving does not succeed', (t) async {
      await render(t);
      await openDialog(t);
      api.fail['setDefaultModels'] = Exception('failed');
      api.calls.clear();
      await t.tap(saveButton);
      await settle(t);
      expect(api.callsOf('setDefaultModels'), hasLength(1));
      expect(saveButton, findsOneWidget);
      expect(find.text('Modified successfully'), findsNothing);
      expect(api.callsOf('defaultModel'), isEmpty);
      expect(api.callsOf('modelsOfType'), isEmpty);
    });

    testWidgets('should disable save without model config permission', (t) async {
      await render(t, permissionKeys: const []);
      await openDialog(t);
      expect(saveEnabled(t), isFalse);
    });

    testWidgets('should pass hide provider settings footer flag to model selectors', (t) async {
      await render(t, hideProviderSettingsFooter: true);
      await openDialog(t);
      final selectors = t.widgetList<ModelSelector>(find.byType(ModelSelector));
      expect(selectors, hasLength(5));
      expect(selectors.every((s) => s.hideProviderSettingsFooter), isTrue);
    });

    testWidgets('should hide model metadata in default model selectors', (t) async {
      await render(t);
      await openDialog(t);
      final selectors = t.widgetList<ModelSelector>(find.byType(ModelSelector));
      expect(selectors, hasLength(5));
      expect(selectors.every((s) => !s.showModelMeta), isTrue);
    });

    testWidgets('should close the dialog from every empty selector configure action', (t) async {
      await render(t, withModels: false);
      for (var index = 0; index < 5; index++) {
        await openDialog(t);
        await t.tap(find.byType(ModelSelector).at(index));
        await settle(t);
        await t.tap(find.bySemanticsLabel('common.modelProvider.selector.configure').last);
        await settle(t);
        expect(saveButton, findsNothing);
      }
    });
  });
}
