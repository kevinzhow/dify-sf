// dify-spec: web/app/components/workflow/panel/env-panel/__tests__/variable-modal.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/env_variable_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

ModelItem createModelItem(String model, String mode) => ModelItem(
  model: model,
  label: {'en_US': model, 'zh_Hans': model},
  features: const [],
  modelProperties: {'mode': mode},
);

ProviderWithModels createModelProvider() => ProviderWithModels(
  provider: 'openai',
  label: const {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
  models: [createModelItem('chat-model', 'chat'), createModelItem('completion-model', 'completion')],
);

/// The model field's ModelParameterModal (Dify's spec mocks it and drives its props).
ModelParameterModal modelModal(WidgetTester t) => t.widget<ModelParameterModal>(find.byType(ModelParameterModal));

bool disabled(WidgetTester t, String label) => t.widget<DifyPressable>(buttonNamed(label)).disabled;

void main() {
  setUp(useDifyTestTranslator);

  Future<void> render(
    WidgetTester t, {
    Map<String, Object?>? env,
    VoidCallback? onClose,
    ValueChanged<Map<String, Object?>>? onSave,
    List<Map<String, Object?>> environmentVariables = const [],
    Map<String, String> envSecrets = const {},
  }) async {
    final store = WorkflowStore()
      ..setEnvironmentVariables(environmentVariables)
      ..setEnvSecrets(envSecrets);
    addTearDown(store.dispose);
    await pumpPanel(
      t,
      SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: EnvVariableModal(env: env, onClose: onClose ?? () {}, onSave: onSave ?? (_) {}),
        ),
      ),
      store: store,
      services: panelServices(models: [createModelProvider()]),
    );
  }

  group('VariableModal', () {
    testWidgets('closes from an accessible icon button', (t) async {
      var closed = 0;
      await render(t, onClose: () => closed++);

      await tap(t, buttonNamed('common.operation.close'));

      expect(closed, 1);
    });

    testWidgets('creates a secret environment variable and normalizes spaces in its name', (t) async {
      final saved = <Map<String, Object?>>[];
      var closed = 0;
      await render(t, onSave: saved.add, onClose: () => closed++);

      await tap(t, find.text('Secret'));
      await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'my secret');
      await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), 'top-secret');
      await type(t, byPlaceholder('workflow.env.modal.descriptionPlaceholder'), 'runtime only');
      await tap(t, buttonNamed('common.operation.save'));

      expect(byDisplayValue('my_secret'), findsOneWidget);
      expect(saved, hasLength(1));
      expect(saved.single['id'], isA<String>());
      expect({...saved.single}..remove('id'), {
        'name': 'my_secret',
        'value': 'top-secret',
        'value_type': 'secret',
        'description': 'runtime only',
      });
      expect(closed, 1);
    });

    testWidgets('rejects invalid and duplicate variable names', (t) async {
      await render(
        t,
        environmentVariables: [
          createEnv({'id': 'env-existing', 'name': 'duplicated', 'value_type': 'string', 'value': '1'}),
        ],
      );

      await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), '1bad');
      expect(toasts, isNotEmpty);

      toasts.clear();
      await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'duplicated');
      await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), '42');
      await tap(t, buttonNamed('common.operation.save'));

      expect(toasts.last, 'app-debug.varKeyError.keyAlreadyExists:{"key":"workflow.env.modal.name"}');
    });

    testWidgets('loads existing secret values and converts them to numbers when editing', (t) async {
      final saved = <Map<String, Object?>>[];
      await render(
        t,
        env: createEnv({'id': 'env-2', 'name': 'counter', 'value': '[__HIDDEN__]', 'description': 'editable'}),
        onSave: saved.add,
        environmentVariables: [
          createEnv({'id': 'env-2', 'name': 'counter'}),
        ],
        envSecrets: {'env-2': '123'},
      );

      expect(byDisplayValue('counter'), findsOneWidget);
      expect(byDisplayValue('123'), findsOneWidget);

      await tap(t, find.text('Number'));
      await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), '9');
      await tap(t, buttonNamed('common.operation.save'));

      expect(saved, [
        {'id': 'env-2', 'name': 'counter', 'value': 9, 'value_type': 'number', 'description': 'editable'},
      ]);
    });

    testWidgets('creates an LLM environment variable from the selected text-generation model', (t) async {
      final saved = <Map<String, Object?>>[];
      await render(t, onSave: saved.add);

      await tap(t, buttonNamed('workflow.blocks.llm'));
      await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'for_summarize');
      modelModal(t).onModelChange((provider: 'openai', modelId: 'chat-model', mode: 'chat', features: const []));
      await t.pump();
      modelModal(t).onCompletionParamsChange({...modelModal(t).completionParams, 'temperature': 0.4});
      await t.pump();
      await tap(t, buttonNamed('common.operation.save'));

      expect(saved, hasLength(1));
      expect({...saved.single}..remove('id'), {
        'name': 'for_summarize',
        'value': {
          'provider': 'openai',
          'name': 'chat-model',
          'mode': 'chat',
          'completion_params': {'temperature': 0.4},
        },
        'value_type': 'llm',
        'description': '',
      });
    });

    testWidgets('rejects an LLM environment variable with an empty model selection', (t) async {
      final saved = <Map<String, Object?>>[];
      final env = createEnv({
        'value': {'mode': '', 'name': '', 'provider': ''},
        'value_type': 'llm',
      });
      await render(t, env: env, onSave: saved.add, environmentVariables: [env]);

      await tap(t, buttonNamed('common.operation.save'));

      expect(toasts, contains('workflow.env.modal.valueRequired'));
      expect(saved, isEmpty);
    });

    testWidgets('keeps an edited LLM environment variable within its existing model mode', (t) async {
      final saved = <Map<String, Object?>>[];
      final env = createEnv({
        'id': 'env-llm',
        'name': 'for_research',
        'value': {'provider': 'openai', 'name': 'chat-model', 'mode': 'chat'},
        'value_type': 'llm',
        'description': 'research model',
      });
      await render(t, env: env, onSave: saved.add, environmentVariables: [env]);

      expect(modelModal(t).modelId, 'chat-model');
      final offered = [
        for (final p in modelModal(t).modelList!)
          for (final m in p.models) m.model,
      ];
      expect(offered, contains('chat-model'));
      expect(offered, isNot(contains('completion-model')));
      expect(disabled(t, 'String'), isTrue);
      expect(disabled(t, 'Number'), isTrue);
      expect(disabled(t, 'Secret'), isTrue);
      expect(disabled(t, 'workflow.blocks.llm'), isFalse);

      modelModal(t)
          .onModelChange((provider: 'openai', modelId: 'completion-model', mode: 'completion', features: const []));
      await t.pump();
      await tap(t, buttonNamed('common.operation.save'));

      expect(toasts, contains('common.modelProvider.selector.incompatibleTip'));
      expect(saved, [env]);
    });
  });
}
