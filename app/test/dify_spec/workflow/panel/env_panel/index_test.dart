// dify-spec: web/app/components/workflow/panel/env-panel/__tests__/index.spec.tsx
//
// Dify's EnvPanel persists through its API (a queue, a draft-sync fallback, rollbacks); here a change is item ops
// on the document's `environment_variables` (under `$app`), so these cases check the ops the panel asks for and
// the node rewrites that go with them.
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/env_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const envPath = ['environment_variables'];

/// A fake secret store: what it was given, and `sec-N` refs with Dify's mask.
class FakeSecrets {
  final stored = <String>[];
  Future<({String ref, String masked})> call(String plaintext) async {
    stored.add(plaintext);
    return (ref: 'sec-${stored.length}', masked: AppRegisters.maskSecret(plaintext));
  }
}

/// An answer node and a code node that use `env.api_key`, and one that does not.
List<Node> nodesUsing(String selector) => [
  difyNode('node-1', 'code', {
    'code_language': 'python3',
    'code': '',
    'outputs': {},
    'variables': [
      {'variable': 'x', 'value_selector': selector.split('.')},
    ],
  }),
  difyNode('node-2', 'answer', {'answer': 'plain', 'variables': []}),
];

Node llmNode(
  String envName, {
  Map<String, Object?> params = const {'temperature': 0.7, 'obsolete': true},
  Map<String, Object?>? vision,
}) => difyNode('llm-node', 'llm', {
  'model': {'provider': 'old-provider', 'name': 'old-model', 'mode': 'chat', 'completion_params': params},
  'model_selector': ['env', envName],
  'prompt_template': [
    {'role': 'system', 'text': ''},
  ],
  'context': {'enabled': false, 'variable_selector': []},
  'vision': vision ?? {'enabled': false},
});

final temperatureRule = {
  'name': 'temperature',
  'type': 'float',
  'min': 0,
  'max': 2,
  'label': {'en_US': 'Temperature', 'zh_Hans': 'Temperature'},
  'required': false,
};

final providers = [
  ProviderWithModels(
    provider: 'new-provider',
    models: [
      ModelItem(model: 'new-model', features: const [], modelProperties: const {'mode': 'chat'}),
    ],
  ),
  ProviderWithModels(
    provider: 'old-provider',
    models: [
      ModelItem(model: 'old-model', features: const ['vision'], modelProperties: const {'mode': 'chat'}),
    ],
  ),
];

void main() {
  setUp(useDifyTestTranslator);

  Future<VarHarness> render(
    WidgetTester t, {
    List<Node> nodes = const [],
    List<Map<String, Object?>> env = const [],
    Map<String, String> envSecrets = const {},
    FakeSecrets? secrets,
    Future<List<Map<String, Object?>>> Function(String, String)? rules,
  }) async {
    final h = await VarHarness.start(t, nodes: nodes, env: env, envSecrets: envSecrets);
    h.store.setShowEnvPanel(true);
    await pumpPanel(
      t,
      EnvPanel(controller: h.controller, storeSecret: secrets?.call),
      store: h.store,
      services: panelServices(models: providers, parameterRules: rules),
    );
    return h;
  }

  Future<void> openEdit(WidgetTester t) async => tap(t, buttonNamed('common.operation.edit'));
  Future<void> save(WidgetTester t) async {
    await tap(t, buttonNamed('common.operation.save'));
    await settle(t);
  }

  ModelParameterModal modelModal(WidgetTester t) => t.widget<ModelParameterModal>(find.byType(ModelParameterModal));

  group('EnvPanel container', () {
    testWidgets('should close the panel from the header action', (t) async {
      final h = await render(t);

      await tap(t, buttonNamed('common.operation.close'));

      expect(h.store.showEnvPanel.value, isFalse);
      await h.dispose(t);
    });

    testWidgets('should add variables and normalize secret values after syncing', (t) async {
      final h = await render(t);

      await tap(t, buttonNamed('workflow.env.envPanelButton'));
      await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'created_name');
      await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), 'created-value');
      await type(t, byPlaceholder('workflow.env.modal.descriptionPlaceholder'), 'created');
      await save(t);

      final op = h.controller.appOps.single;
      final value = op.value! as Map;
      expect(op.kind, 'insert');
      expect(op.path, envPath);
      expect(op.id, value['id']);
      expect({...value}..remove('id'), {
        'name': 'created_name',
        'value': 'created-value',
        'value_type': 'string',
        'description': 'created',
      });
      expect(h.controller.nodeOps, isEmpty);
      await h.dispose(t);
    });

    testWidgets('should delete unused variables and sync draft changes', (t) async {
      final env = createEnv({'value_type': 'string', 'value': 'plain-text'});
      final h = await render(t, env: [env]);

      await tap(t, buttonNamed('common.operation.delete'));

      expect(h.controller.appOps, [
        (kind: 'remove', node: r'$app', path: envPath, id: 'env-1', value: null, base: null),
      ]);
      expect(h.controller.nodeOps, isEmpty);
      await h.dispose(t);
    });

    testWidgets('should add secret variables, persist masked secrets, and sanitize the stored env value', (t) async {
      final secrets = FakeSecrets();
      final h = await render(t, secrets: secrets);

      await tap(t, buttonNamed('workflow.env.envPanelButton'));
      await tap(t, find.text('Secret'));
      await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'secret_key');
      await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), '1234567890');
      await save(t);

      expect(secrets.stored, ['1234567890']);
      final value = h.controller.appOps.single.value! as Map;
      expect(value['value'], '123456************90');
      expect(value['secret_ref'], 'sec-1');
      expect(value['value_type'], 'secret');
      expect(h.controller.ops.toString(), isNot(contains('1234567890')));
      await h.dispose(t);
    });

    testWidgets('should clear the current variable when the variable modal closes', (t) async {
      final env = createEnv({'value_type': 'string', 'value': 'plain-text'});
      final h = await render(t, env: [env]);

      await openEdit(t);
      expect(find.text('workflow.env.modal.editTitle'), findsOneWidget);
      expect(byDisplayValue('api_key'), findsOneWidget);

      await tap(t, buttonNamed('common.operation.cancel'));
      await tap(t, buttonNamed('workflow.env.envPanelButton'));

      expect(find.text('workflow.env.modal.title'), findsOneWidget);
      expect(byDisplayValue('api_key'), findsNothing);
      await h.dispose(t);
    });

    testWidgets(
      'should rename existing secret variables and update affected nodes without re-saving unchanged secrets',
      (t) async {
        final secrets = FakeSecrets();
        final env = createEnv({'value': 'abcdef************56', 'secret_ref': 'sec-old'});
        final h = await render(t, nodes: nodesUsing('env.api_key'), env: [env], secrets: secrets);
        final seen = h.controller.seenVersion;

        await openEdit(t);
        await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'renamed_key');
        await save(t);

        expect(secrets.stored, isEmpty);
        expect(h.controller.appOps.single.kind, 'update');
        expect(h.controller.appOps.single.base, seen);
        expect(h.controller.appOps.single.value, {
          'id': 'env-1',
          'name': 'renamed_key',
          'value': 'abcdef************56',
          'value_type': 'secret',
          'description': 'secret description',
          'secret_ref': 'sec-old',
        });
        expect(difyDataOf(h.doc.nodes['node-1']!)['variables'], [
          {
            'variable': 'x',
            'value_selector': ['env', 'renamed_key'],
          },
        ]);
        expect(h.controller.nodeOps.every((o) => o.node == 'node-1'), isTrue);
        expect(h.store.controlPromptEditorRerenderKey.value, greaterThan(0));
        await h.dispose(t);
      },
    );

    testWidgets('should convert edited plain variables into secrets and store the masked secret value', (t) async {
      final secrets = FakeSecrets();
      final env = createEnv({'value_type': 'string', 'value': 'plain-text'});
      final h = await render(t, env: [env], secrets: secrets);

      await openEdit(t);
      await tap(t, find.text('Secret'));
      await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), 'abcdef123456');
      await save(t);

      expect(secrets.stored, ['abcdef123456']);
      final value = h.controller.appOps.single.value! as Map;
      expect(value['value_type'], 'secret');
      expect(value['value'], 'abcdef************56');
      expect(value['secret_ref'], 'sec-1');
      expect(h.controller.ops.toString(), isNot(contains('abcdef123456')));
      await h.dispose(t);
    });

    testWidgets('should reconcile nodes when a shared LLM model changes', (t) async {
      final env = createEnv({
        'name': 'shared_model',
        'value_type': 'llm',
        'value': {'provider': 'old-provider', 'name': 'old-model', 'mode': 'chat'},
      });
      final h = await render(
        t,
        nodes: [
          llmNode(
            'shared_model',
            vision: {
              'enabled': true,
              'configs': {
                'detail': 'low',
                'variable_selector': ['sys', 'files'],
              },
            },
          ),
        ],
        env: [env],
        rules: (_, _) async => [temperatureRule],
      );

      await openEdit(t);
      modelModal(t).onModelChange((provider: 'new-provider', modelId: 'new-model', mode: 'chat', features: const []));
      await t.pump();
      await save(t);

      final data = difyDataOf(h.doc.nodes['llm-node']!);
      expect(data['model'], {
        'provider': 'new-provider',
        'name': 'new-model',
        'mode': 'chat',
        'completion_params': {'temperature': 0.7},
      });
      expect(data['vision'], {'enabled': false});
      final update = h.controller.appOps.single;
      expect(update.kind, 'update');
      expect((update.value! as Map)['value'], containsPair('name', 'new-model'));
      await h.dispose(t);
    });

    testWidgets('should persist shared LLM parameters without rewriting referenced nodes', (t) async {
      final env = createEnv({
        'name': 'shared_model',
        'value_type': 'llm',
        'value': {
          'provider': 'old-provider',
          'name': 'old-model',
          'mode': 'chat',
          'completion_params': {'temperature': 0.2},
        },
      });
      final h = await render(t, nodes: [llmNode('shared_model')], env: [env], rules: (_, _) async => [temperatureRule]);

      await openEdit(t);
      modelModal(t).onCompletionParamsChange({'temperature': 0.8});
      await t.pump();
      await save(t);

      expect(h.controller.appOps.single.value, {
        ...env,
        'value': {
          'provider': 'old-provider',
          'name': 'old-model',
          'mode': 'chat',
          'completion_params': {'temperature': 0.8},
        },
      });
      expect(h.controller.nodeOps, isEmpty);
      await h.dispose(t);
    });

    testWidgets('should reconcile the latest node parameters after model rules finish loading', (t) async {
      final env = createEnv({
        'name': 'shared_model',
        'value_type': 'llm',
        'value': {'provider': 'old-provider', 'name': 'old-model', 'mode': 'chat'},
      });
      final rules = Completer<List<Map<String, Object?>>>();
      var fetched = 0;
      final h = await render(
        t,
        nodes: [
          llmNode('shared_model', params: const {'temperature': 0.2}),
        ],
        env: [env],
        rules: (_, _) {
          fetched++;
          return rules.future;
        },
      );

      await openEdit(t);
      modelModal(t).onModelChange((provider: 'new-provider', modelId: 'new-model', mode: 'chat', features: const []));
      await t.pump();
      final before = fetched; // the modal's model settings load the rules too
      await save(t);
      expect(fetched - before, 1);
      expect(h.controller.appOps, isEmpty);

      h.controller.setConfig('llm-node', [
        'model',
        'completion_params',
      ], Value.of({'temperature': 0.9, 'obsolete': true}));
      rules.complete([temperatureRule]);
      await settle(t);

      expect((difyDataOf(h.doc.nodes['llm-node']!)['model']! as Map)['completion_params'], {'temperature': 0.9});
      await h.dispose(t);
    });

    testWidgets('should preserve the shared model and nodes when model rules cannot be fetched', (t) async {
      final env = createEnv({
        'name': 'shared_model',
        'value_type': 'llm',
        'value': {'provider': 'old-provider', 'name': 'old-model', 'mode': 'chat'},
      });
      var fetched = 0;
      final h = await render(
        t,
        nodes: [llmNode('shared_model')],
        env: [env],
        rules: (_, _) async {
          fetched++;
          throw StateError('network error');
        },
      );

      await openEdit(t);
      modelModal(t).onModelChange((provider: 'new-provider', modelId: 'new-model', mode: 'chat', features: const []));
      await t.pump();
      final before = fetched; // the modal's model settings load the rules too
      await save(t);

      expect(fetched - before, 1);
      expect(h.controller.ops, isEmpty);
      expect(toasts, contains('common.error'));
      await h.dispose(t);
    });

    testWidgets('should persist a new masked secret when an existing secret variable changes value', (t) async {
      final secrets = FakeSecrets();
      final env = createEnv({'value': '********************', 'secret_ref': 'sec-old'});
      final h = await render(t, env: [env], secrets: secrets);

      await openEdit(t);
      await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), 'updated-secret-99');
      await save(t);

      expect(secrets.stored, ['updated-secret-99']);
      final value = h.controller.appOps.single.value! as Map;
      expect(value['value'], 'update************99');
      expect(value['secret_ref'], 'sec-1');
      expect(h.controller.ops.toString(), isNot(contains('updated-secret-99')));
      await h.dispose(t);
    });

    testWidgets('should require confirmation before deleting affected secret variables', (t) async {
      final env = createEnv({'value': 'abcdef************56', 'secret_ref': 'sec-old'});
      final h = await render(t, nodes: nodesUsing('env.api_key'), env: [env]);

      await tap(t, buttonNamed('common.operation.delete'));
      expect(find.text('workflow.common.effectVarConfirm.title'), findsOneWidget);
      expect(h.controller.ops, isEmpty);

      await tap(t, buttonNamed('common.operation.cancel'));
      expect(find.text('workflow.common.effectVarConfirm.title'), findsNothing);
      expect(h.controller.ops, isEmpty);

      await tap(t, buttonNamed('common.operation.delete'));
      await tap(t, buttonNamed('common.operation.confirm'));

      expect(h.controller.appOps.single, (
        kind: 'remove',
        node: r'$app',
        path: envPath,
        id: 'env-1',
        value: null,
        base: null,
      ));
      expect(difyDataOf(h.doc.nodes['node-1']!)['variables'], [
        {'variable': 'x', 'value_selector': <Object?>[]},
      ]);
      await h.dispose(t);
    });
  });
}
