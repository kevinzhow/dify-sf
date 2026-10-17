// dify-spec: web/app/components/workflow/nodes/agent/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/agent/__tests__/use-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/agent/__tests__/integration.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/agent-strategy.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/agent-strategy-selector.spec.tsx
//
// The classic Agent panel over a document: strategies come from the services' strategy providers (Dify's
// useStrategyProviders / useStrategyProviderDetail), the use-config logic is agent_model.dart. Where Dify mocks
// AgentStrategy or MemoryConfig and clicks their stand-in buttons, the cases call the real widgets' callbacks.
import 'dart:async';

import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_model.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/panel_edit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> _param(
  String name, {
  String type = 'any',
  bool required = true,
  Map<String, Object?> o = const {},
}) => {
  'name': name,
  'type': type,
  'required': required,
  'label': {'en_US': name == 'instruction' ? 'Instruction' : name},
  'help': {'en_US': '$name help'},
  'placeholder': {'en_US': '$name placeholder'},
  'scope': 'global',
  'default': null,
  'options': <Object?>[],
  'template': {'enabled': false},
  'auto_generate': {'type': 'none'},
  ...o,
};

Map<String, Object?> _provider(
  String name,
  List<Map<String, Object?>> strategies, {
  String version = '1.0.0',
}) => {
  'provider': name,
  'plugin_unique_identifier': '$name:$version',
  'plugin_id': name,
  'declaration': {
    'identity': {
      'author': 'provider',
      'name': name,
      'label': {'en_US': '$name label'},
      'icon': 'icon.png',
    },
    'strategies': strategies,
  },
  'meta': {'version': version},
};

Map<String, Object?> _strategy(
  String name,
  String label,
  List<Map<String, Object?>> parameters, {
  List<String> features = const [],
}) => {
  'identity': {
    'name': name,
    'author': 'provider',
    'label': {'en_US': label},
  },
  'description': {'en_US': '$label description'},
  'parameters': parameters,
  'output_schema': {
    'properties': {
      'structured': {'type': 'string', 'description': 'structured output'},
    },
  },
  'features': features,
};

final _providers = [
  _provider('provider/agent', [
    _strategy(
      'react',
      'React Agent',
      [
        _param('instruction'),
        _param('modelParam', type: 'model-selector', required: false),
      ],
      features: [agentFeatureHistoryMessages],
    ),
  ]),
  _provider('provider/updated', [_strategy('updated', 'Updated Strategy', const [])]),
];

Map<String, Object?> _data([Map<String, Object?> overrides = const {}]) => {
  'output_schema': {
    'properties': {
      'summary': {'type': 'string', 'description': 'summary output'},
    },
  },
  'agent_strategy_provider_name': 'provider/agent',
  'agent_strategy_name': 'react',
  'agent_strategy_label': 'React Agent',
  'plugin_unique_identifier': 'provider/agent:1.0.0',
  'meta': {'version': '1.0.0'},
  'tool_node_version': '2',
  'agent_parameters': {
    'instruction': {'type': 'variable', 'value': 'Plan and answer'},
  },
  'memory': {
    'window': {'enabled': false, 'size': 3},
    'query_prompt_template': '',
  },
  ...overrides,
};

Finder _varItem(String name, String type, String description) => find.byWidgetPredicate(
  (w) => w is VarItem && w.name == name && w.type == type && w.description == description,
  description: 'VarItem $name:$type:$description',
);

/// Opens the "Output Variables" collapse (closed at first).
Future<void> _openOutputs(WidgetTester t) async {
  await t.tap(find.textContaining('WORKFLOW.NODES.COMMON.OUTPUTVARS', findRichText: true));
  await settle(t);
}

Widget _host(Widget child, {LlmGroupServices services = LlmGroupServices.empty}) => MaterialApp(
  home: Material(
    child: LlmGroupScope(
      services: services,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 900, child: SingleChildScrollView(child: child)),
      ),
    ),
  ),
);

void main() {
  setUp(useDifyTestTranslator);

  Future<Harness> render(
    WidgetTester t, {
    Map<String, Object?> data = const {},
    bool chatMode = true,
    LlmGroupServices? services,
  }) => startPanel(
    t,
    [('agent', 'agent', _data(data))],
    chatMode: chatMode,
    services: services ?? LlmGroupServices(strategyProviders: _providers),
  );

  group('agent/panel', () {
    testWidgets('renders strategy data, forwards strategy and form updates, and exposes output vars', (t) async {
      final h = await render(t);
      await _openOutputs(t);
      expect(_varItem('text', 'String', 'workflow.nodes.agent.outputVars.text'), findsOneWidget);
      expect(_varItem('usage', 'object', 'workflow.nodes.agent.outputVars.usage'), findsOneWidget);
      expect(_varItem('files', 'Array[File]', 'workflow.nodes.agent.outputVars.files.title'), findsOneWidget);
      expect(_varItem('json', 'Array[Object]', 'workflow.nodes.agent.outputVars.json'), findsOneWidget);
      expect(_varItem('summary', 'String', 'summary output'), findsOneWidget);
      final form = t.widget<AgentStrategyForm>(find.byType(AgentStrategyForm));
      expect(
        form.schemas,
        containsAll([
          allOf(containsPair('variable', 'instruction'), containsPair('tooltip', {'en_US': 'instruction help'})),
          containsPair('variable', 'modelParam'),
        ]),
      );
      expect(form.value, {'instruction': 'Plan and answer'});

      final keyBefore = h.store.controlPromptEditorRerenderKey.value;
      await t.tap(find.text('React Agent'));
      await settle(t);
      await t.tap(find.text('Updated Strategy'));
      await settle(t);
      final d = dataOf(h, 'agent');
      expect(d['agent_strategy_provider_name'], 'provider/updated');
      expect(d['agent_strategy_name'], 'updated');
      expect(d['agent_strategy_label'], 'Updated Strategy');
      expect(d['plugin_unique_identifier'], 'provider/updated:1.0.0');
      expect((d['output_schema']! as Map)['properties'], contains('structured'));
      expect(h.store.controlPromptEditorRerenderKey.value, isNot(keyBefore));

      // Back to the strategy with the form and memory.
      setInputs(propsOf(h), {...dataOf(h, 'agent'), ..._data()});
      await settle(t);
      t.widget<AgentStrategyForm>(find.byType(AgentStrategyForm)).onChange({'instruction': 'Use the tool'});
      await settle(t);
      expect((dataOf(h, 'agent')['agent_parameters']! as Map)['instruction'], {
        'type': 'variable',
        'value': 'Use the tool',
      });
      t.widget<MemoryConfig>(find.byType(MemoryConfig)).onChange({
        'window': {'enabled': true, 'size': 8},
        'query_prompt_template': 'history',
      });
      await settle(t);
      expect((dataOf(h, 'agent')['memory']! as Map)['query_prompt_template'], 'history');
      await h.dispose(t);
    });

    testWidgets('hides memory config when chat mode support is unavailable', (t) async {
      final h = await render(t, chatMode: false);
      expect(find.byType(MemoryConfig), findsNothing);
      await h.dispose(t);
    });
  });

  group('agent/use-config', () {
    testWidgets(
      'returns an undefined strategy status while strategy data is still loading and can refetch dependencies',
      (t) async {
        expect(strategyStatusOf(loading: true, isError: false, strategy: null), isNull);
        expect(findStrategy(null, 'react'), isNull);
        final calls = <String>[];
        final pending = <Completer<Map<String, Object?>?>>[];
        final h = await render(
          t,
          services: LlmGroupServices(
            fetchStrategy: (p) {
              calls.add(p);
              pending.add(Completer());
              return pending.last.future;
            },
          ),
        );
        expect(t.widget<AgentStrategy>(find.byType(AgentStrategy)).status, isNull);
        t.widget<AgentStrategy>(find.byType(AgentStrategy)).onRefetch!();
        await settle(t);
        expect(calls, ['provider/agent', 'provider/agent']);
        await h.dispose(t);
      },
    );

    test('resolves strategy status for external plugins that are missing or not installed', () {
      expect(strategyStatusOf(loading: false, isError: true, strategy: null), (
        source: 'external',
        installed: false,
        isExistInPlugin: false,
      ));
    });

    test('exposes derived form data, strategy state, output schema, and setter helpers', () {
      final strategy = {
        'parameters': [
          _param('instruction'),
          _param('modelParam', type: 'model-selector', required: false),
        ],
      };
      final inputs = _data({
        'output_schema': {
          'properties': {
            'summary': {'type': 'string', 'description': 'summary output'},
            'items': {
              'type': 'array',
              'items': {'type': 'number'},
              'description': 'items output',
            },
          },
        },
        'agent_parameters': {
          'instruction': {'type': 'variable', 'value': '#start.topic#'},
          'modelParam': {
            'type': 'constant',
            'value': {'provider': 'openai', 'model': 'gpt-4o'},
          },
        },
      });
      expect(agentFormData(inputs, strategy), {
        'instruction': '#start.topic#',
        'modelParam': {'provider': 'openai', 'model': 'gpt-4o'},
      });
      expect(strategyStatusOf(loading: false, isError: false, strategy: strategy, isInMarketplace: true), (
        source: 'marketplace',
        installed: true,
        isExistInPlugin: true,
      ));
      expect(agentOutputSchema(inputs), [
        (name: 'summary', type: 'String', description: 'summary output'),
        (name: 'items', type: 'Array[Number]', description: 'items output'),
      ]);
      expect(
        agentParametersOf({
          'instruction': '#start.updated#',
          'modelParam': {'provider': 'anthropic', 'model': 'claude-sonnet'},
        }, strategy),
        {
          'instruction': {'type': 'variable', 'value': '#start.updated#'},
          'modelParam': {
            'type': 'constant',
            'value': {'provider': 'anthropic', 'model': 'claude-sonnet'},
          },
        },
      );
    });

    testWidgets('formats legacy tool selector values before exposing the node config', (t) async {
      Map<String, Object?> toolValue() => {
        'settings': {'api_key': 'secret'},
        'parameters': {'query': 'weather'},
        'schemas': [
          {'variable': 'api_key', 'name': 'api_key', 'form': 'form', 'type': 'secret-input'},
          {'variable': 'query', 'name': 'query', 'form': 'llm', 'type': 'string'},
        ],
      };
      final h = await render(
        t,
        data: {
          'tool_node_version': null,
          'agent_parameters': {
            'toolParam': {'type': 'constant', 'value': toolValue()},
            'multiToolParam': {
              'type': 'constant',
              'value': [toolValue()],
            },
          },
        },
        services: LlmGroupServices(
          strategyProviders: [
            _provider('provider/agent', [
              _strategy('react', 'React Agent', [
                _param('toolParam', type: 'tool-selector', required: false),
                _param('multiToolParam', type: 'array[tools]', required: false),
              ]),
            ]),
          ],
        ),
      );
      final d = dataOf(h, 'agent');
      expect(d['tool_node_version'], '2');
      final params = d['agent_parameters']! as Map;
      Map<String, Object?> formatted(Object? v) => (v! as Map).cast<String, Object?>();
      final tool = formatted((params['toolParam']! as Map)['value']);
      expect(tool['settings'], {
        'api_key': {
          'value': {'type': 'mixed', 'value': null},
        },
      });
      expect(tool['parameters'], {
        'query': {
          'auto': 0,
          'value': {'type': 'mixed', 'value': null},
        },
      });
      final multi = formatted(((params['multiToolParam']! as Map)['value']! as List).single);
      expect(multi['settings'], tool['settings']);
      expect(multi['parameters'], tool['parameters']);
      await h.dispose(t);
    });
  });

  group('agent path', () {
    group('Path Integration', () {
      testWidgets('should render the panel, update the selected strategy, and expose memory plus output vars', (
        t,
      ) async {
        final h = await render(
          t,
          data: {
            'output_schema': {
              'properties': {
                'jsonField': {'type': 'string', 'description': 'json output'},
              },
            },
          },
        );
        expect(find.textContaining('WORKFLOW.NODES.AGENT.STRATEGY.LABEL', findRichText: true), findsOneWidget);
        await _openOutputs(t);
        expect(_varItem('text', 'String', 'workflow.nodes.agent.outputVars.text'), findsOneWidget);
        expect(_varItem('jsonField', 'String', 'json output'), findsOneWidget);
        await t.tap(find.text('React Agent'));
        await settle(t);
        await t.tap(find.text('Updated Strategy'));
        await settle(t);
        expect(dataOf(h, 'agent')['agent_strategy_provider_name'], 'provider/updated');
        await h.dispose(t);
      });
    });
  });

  group('AgentStrategy', () {
    Widget strategyWith(List<Map<String, Object?>> schemas, Harness h) => _host(
      Builder(
        builder: (context) => AgentStrategy(
          strategy: (
            providerName: 'provider',
            strategyName: 'strategy',
            label: 'Strategy',
            outputSchema: const {},
            pluginUniqueIdentifier: 'plugin',
            meta: null,
          ),
          onStrategyChange: (_) {},
          formSchemas: schemas,
          formValue: const {},
          onFormValueChange: (_) {},
          vars: NodeVars.of(context, propsOf(h)),
          props: propsOf(h),
        ),
      ),
    );

    Map<String, Object?> number(Map<String, Object?> o) => {
      'name': 'count',
      'variable': 'count',
      'label': {'en_US': 'Count'},
      'type': 'number-input',
      'required': false,
      'show_on': <Object?>[],
      'default': '1',
      ...o,
    };

    testWidgets('should render text-number schemas when min and max are zero', (t) async {
      final h = await render(t);
      await t.pumpWidget(
        strategyWith([
          number({'min': 0, 'max': 0, 'default': '0'}),
        ], h),
      );
      await settle(t);
      expect(find.byWidgetPredicate((w) => w is DifyNumberField && w.semanticLabel == 'Count'), findsOneWidget);
      expect(find.byType(DifySlider), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('should skip text-number schemas when min is missing', (t) async {
      final h = await render(t);
      await t.pumpWidget(
        strategyWith([
          number({'max': 5}),
        ], h),
      );
      await settle(t);
      // The slider override is skipped: Form's plain number input renders instead.
      expect(find.byType(DifySlider), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should skip text-number schemas when max is missing', (t) async {
      final h = await render(t);
      await t.pumpWidget(
        strategyWith([
          number({'min': 0}),
        ], h),
      );
      await settle(t);
      expect(find.byType(DifySlider), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should render text-input schemas through the editor override', (t) async {
      final h = await render(t);
      await t.pumpWidget(
        strategyWith([
          {
            'name': 'prompt',
            'variable': 'prompt',
            'label': {'en_US': 'Prompt'},
            'type': 'text-input',
            'required': false,
            'show_on': <Object?>[],
            'default': 'hello',
          },
        ], h),
      );
      await settle(t);
      expect(t.widget<DifyPromptEditorPanel>(find.byType(DifyPromptEditorPanel)).value, 'hello');
      await h.dispose(t);
    });
  });

  group('AgentStrategySelector', () {
    final alpha = _provider('alpha', [_strategy('alpha-strategy', 'Alpha Strategy', const [])]);
    final beta = _provider('beta', [_strategy('beta-strategy', 'Beta Strategy', const [])]);

    Future<List<AgentStrategyRef>> pump(WidgetTester t, {AgentStrategyRef? value, AgentStrategyStatus? status}) async {
      final picked = <AgentStrategyRef>[];
      await t.pumpWidget(
        _host(
          AgentStrategySelector(value: value, status: status, onChange: picked.add),
          services: LlmGroupServices(strategyProviders: [alpha, beta]),
        ),
      );
      await settle(t);
      return picked;
    }

    testWidgets('filters strategies and queries marketplace when searching', (t) async {
      await pump(t);
      await t.tap(find.text('workflow.nodes.agent.strategy.selectTip'));
      await settle(t);
      expect(find.text('alpha label'), findsOneWidget);
      expect(find.text('beta label'), findsOneWidget);
      await t.enterText(find.byType(EditableText).last, 'alp');
      await settle(t);
      expect(find.text('alpha label'), findsOneWidget);
      expect(find.text('beta label'), findsNothing);
    });

    testWidgets('maps the selected tool and closes the popover', (t) async {
      final picked = await pump(t);
      await t.tap(find.text('workflow.nodes.agent.strategy.selectTip'));
      await settle(t);
      await t.tap(find.text('Alpha Strategy'));
      await settle(t);
      final p = picked.single;
      expect(p.providerName, 'alpha');
      expect(p.strategyName, 'alpha-strategy');
      expect(p.label, 'Alpha Strategy');
      expect(p.outputSchema, {
        'properties': {
          'structured': {'type': 'string', 'description': 'structured output'},
        },
      });
      expect(p.pluginUniqueIdentifier, 'alpha:1.0.0');
      expect(p.meta, {'version': '1.0.0'});
      expect(find.text('alpha label'), findsNothing);
    });

    testWidgets('renders the plugin-not-installed warning for external strategies', (t) async {
      await pump(
        t,
        value: (
          providerName: 'provider/alpha',
          strategyName: 'alpha-strategy',
          label: 'Alpha Strategy',
          outputSchema: const {},
          pluginUniqueIdentifier: 'provider/alpha',
          meta: null,
        ),
        status: (source: 'external', installed: false, isExistInPlugin: true),
      );
      final warn = find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'error-warning-fill');
      expect(warn, findsOneWidget);
      final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(t.getCenter(warn));
      await settle(t, 800);
      expect(find.text('workflow.nodes.agent.pluginNotInstalledDesc'), findsOneWidget);
      await gesture.removePointer();
    });
  });
}

/// The panel props of the node under test.
NodePanelProps propsOf(Harness h) => NodePanelProps(node: h['agent']!, controller: h.controller, actions: h.actions());
