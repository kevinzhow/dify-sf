// dify-spec: web/app/components/workflow/nodes/llm/__tests__/panel.spec.tsx
//
// The LLM panel over a document in an in-memory session: instead of mocking useConfig, the cases act on the panel
// and read the node's data. The model parameter modal is driven through its onModelChange (Dify mocks it with a
// "Select direct model" button); model parameter rules come from the services (Dify's fetchAndMergeValidCompletionParams).
import 'dart:async';

import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _openai = ModelProvider(provider: 'openai', label: {'en_US': 'OpenAI'});

Map<String, Object?> _llm([Map<String, Object?> overrides = const {}]) => {
  'model': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat', 'completion_params': <String, Object?>{}},
  'prompt_template': <Object?>[],
  'context': {'enabled': false, 'variable_selector': <String>[]},
  'vision': {'enabled': false},
  ...overrides,
};

const _envVars = [
  {
    'id': 'env-llm',
    'name': 'for_summarize',
    'value_type': 'llm',
    'value': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat'},
    'description': '',
  },
  {'id': 'env-string', 'name': 'API_KEY', 'value_type': 'string', 'value': 'secret', 'description': ''},
];

Finder _warningDot() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_WarningDot');
ModelParameterModal _modal(WidgetTester t) => t.widget<ModelParameterModal>(find.byType(ModelParameterModal));
Map<String, Object?> _model(Harness h) => (dataOf(h, 'llm')['model']! as Map).cast<String, Object?>();

void main() {
  setUp(useDifyTestTranslator);

  Future<Harness> render(
    WidgetTester t, {
    Map<String, Object?> data = const {},
    LlmGroupServices services = const LlmGroupServices(models: ModelCatalog(providers: [_openai])),
    List<Map<String, Object?>> env = const [],
  }) async {
    final h = await startPanel(t, [('llm', 'llm', _llm(data))], services: services, chatMode: true, pump: false);
    h.store.setEnvironmentVariables(env);
    await t.pumpWidget(llmPanel(h, 'llm', services: services, chatMode: true));
    await settle(t);
    return h;
  }

  group('LLM Panel', () {
    group('Model Warning Dot', () {
      testWidgets('should not show the model warning dot when the node only has a connection checklist issue', (
        t,
      ) async {
        final h = await render(t);
        expect(find.textContaining('WORKFLOW.NODES.LLM.MODEL', findRichText: true), findsOneWidget);
        expect(_warningDot(), findsNothing);
        await h.dispose(t);
      });

      testWidgets('should show the model warning dot when the model is not configured', (t) async {
        final h = await render(
          t,
          data: {
            'model': {'provider': '', 'name': '', 'mode': 'chat', 'completion_params': <String, Object?>{}},
          },
        );
        expect(_warningDot(), findsOneWidget);
        await h.dispose(t);
      });
    });

    testWidgets('switches from direct model input to an environment reference source', (t) async {
      final h = await render(t);
      await t.tap(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.variable'));
      await settle(t);
      expect(dataOf(h, 'llm')['model_selector'], <String>[]);
      await h.dispose(t);
    });

    testWidgets('does not offer an environment model source in snippet flows', (t) async {
      final h = await render(t, services: const LlmGroupServices(flowType: 'snippet'));
      expect(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.variable'), findsNothing);
      expect(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.input'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('allows a pasted environment-bound snippet node to recover to a direct model', (t) async {
      final h = await render(
        t,
        data: {
          'model_selector': ['env', 'shared_model'],
        },
        services: const LlmGroupServices(flowType: 'snippet'),
      );
      await t.tap(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.input'));
      await settle(t);
      expect(dataOf(h, 'llm')['model_selector'], isNull);
      await h.dispose(t);
    });

    testWidgets('lists only LLM environment variables and binds the selected reference', (t) async {
      final h = await render(
        t,
        data: {'model_selector': <String>[]},
        env: _envVars,
        services: LlmGroupServices(parameterRules: (_, _) async => const []),
      );
      expect(_modal(t).modelSelectorReadonly, isTrue);
      expect(_modal(t).readonly, isTrue);
      await t.tap(find.text('workflow.nodes.common.typeSwitch.variable'));
      await settle(t);
      expect(find.text('for_summarize'), findsOneWidget);
      expect(find.text('API_KEY'), findsNothing);
      await t.tap(find.text('for_summarize'));
      await settle(t);
      expect(dataOf(h, 'llm')['model_selector'], ['env', 'for_summarize']);
      expect(_model(h)['completion_params'], <String, Object?>{});
      await h.dispose(t);
    });

    testWidgets('does not apply stale model parameters after switching back to direct input', (t) async {
      final rules = Completer<List<Map<String, Object?>>>();
      final h = await render(
        t,
        data: {'model_selector': <String>[]},
        env: _envVars,
        services: LlmGroupServices(parameterRules: (_, _) => rules.future),
      );
      await t.tap(find.text('workflow.nodes.common.typeSwitch.variable'));
      await settle(t);
      await t.tap(find.text('for_summarize'));
      await settle(t);
      expect(dataOf(h, 'llm')['model_selector'], <String>[]);

      await t.tap(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.input'));
      await settle(t);
      rules.complete(const []);
      await settle(t);
      expect(dataOf(h, 'llm')['model_selector'], isNull);
      expect(_model(h)['completion_params'], <String, Object?>{});
      await h.dispose(t);
    });

    testWidgets('does not overwrite parameters edited while a model rules request is in flight', (t) async {
      final rules = Completer<List<Map<String, Object?>>>();
      final h = await render(
        t,
        data: {
          'model': {
            'provider': 'openai',
            'name': 'gpt-4o',
            'mode': 'chat',
            'completion_params': {'temperature': 0.7},
          },
        },
        services: LlmGroupServices(parameterRules: (_, _) => rules.future),
      );
      _modal(t).onModelChange((provider: 'anthropic', modelId: 'claude-3-5-sonnet', mode: null, features: const []));
      await settle(t);
      _modal(t).onCompletionParamsChange({'temperature': 0.9});
      await settle(t);
      rules.complete(const [
        {'name': 'temperature', 'type': 'float', 'min': 0, 'max': 2},
      ]);
      await settle(t);
      expect(_model(h)['provider'], 'openai');
      expect(_model(h)['completion_params'], {'temperature': 0.9});
      await h.dispose(t);
    });

    testWidgets('commits a direct model and its filtered parameters together', (t) async {
      final rules = Completer<List<Map<String, Object?>>>();
      final h = await render(
        t,
        data: {
          'model': {
            'provider': 'openai',
            'name': 'gpt-4o',
            'mode': 'chat',
            'completion_params': {'temperature': 0.7, 'unknown': 1},
          },
        },
        services: LlmGroupServices(parameterRules: (_, _) => rules.future),
      );
      _modal(t).onModelChange((provider: 'anthropic', modelId: 'claude-3-5-sonnet', mode: 'chat', features: const []));
      await settle(t);
      expect(_model(h)['provider'], 'openai');
      rules.complete(const [
        {'name': 'temperature', 'type': 'float', 'min': 0, 'max': 2},
      ]);
      await settle(t);
      expect(_model(h)['provider'], 'anthropic');
      expect(_model(h)['name'], 'claude-3-5-sonnet');
      expect(_model(h)['completion_params'], {'temperature': 0.7});
      await h.dispose(t);
    });

    testWidgets('preserves completion parameters when model rules cannot be fetched', (t) async {
      final toasts = <String>[];
      final h = await render(
        t,
        data: {
          'model': {
            'provider': 'openai',
            'name': 'gpt-4o',
            'mode': 'chat',
            'completion_params': {'temperature': 0.7},
          },
        },
        services: LlmGroupServices(
          parameterRules: (_, _) async => throw Exception('network error'),
          toast: (type, m) => toasts.add('$type $m'),
        ),
      );
      _modal(t).onModelChange((provider: 'anthropic', modelId: 'claude-3-5-sonnet', mode: 'chat', features: const []));
      await settle(t);
      expect(_model(h)['provider'], 'openai');
      expect(_model(h)['completion_params'], {'temperature': 0.7});
      expect(toasts, ['LlmToastType.error common.error']);
      await h.dispose(t);
    });
  });
}
