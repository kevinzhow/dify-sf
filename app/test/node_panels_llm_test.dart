import 'dart:io';
import 'dart:ui' as ui;

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/panel_edit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/nodes_panel/llm/harness.dart';
import 'support/app_fonts.dart';

NodePanelProps propsOf(Harness h, String id) =>
    NodePanelProps(node: h[id]!, controller: h.controller, actions: h.actions());

void main() {
  group('screenshots', screenshots);
  setUp(useDifyTestTranslator);

  group('setInputs', () {
    testWidgets('writes only the changed leaf of nested maps', (t) async {
      final h = await startPanel(t, [
        ('start', 'start', {'variables': []}),
        (
          'llm',
          'llm',
          {
            'model': {
              'provider': 'p',
              'name': 'm',
              'mode': 'chat',
              'completion_params': {'temperature': 0.7},
            },
            'vision': {'enabled': false},
            'context': {'enabled': false, 'variable_selector': []},
          },
        ),
      ], pump: false);
      setInputs(propsOf(h, 'llm'), {
        ...dataOf(h, 'llm'),
        'vision': {'enabled': true},
        'context': {
          'enabled': true,
          'variable_selector': ['start', 'x'],
        },
      });
      await settle(t);
      final d = dataOf(h, 'llm');
      expect(d['vision'], {'enabled': true});
      expect(d['context'], {
        'enabled': true,
        'variable_selector': ['start', 'x'],
      });
      expect((d['model'] as Map)['completion_params'], {'temperature': 0.7});
      await h.dispose(t);
    });

    testWidgets('edits keyed lists by id: update, insert, remove and move', (t) async {
      final h = await startPanel(t, [
        (
          'llm',
          'llm',
          {
            'prompt_template': [
              {'id': 'a', 'role': 'system', 'text': 'A'},
              {'id': 'b', 'role': 'user', 'text': 'B'},
              {'id': 'c', 'role': 'assistant', 'text': 'C'},
            ],
          },
        ),
      ], pump: false);
      expect(h['llm']!.config['prompt_template'], isA<VItems>());
      setInputs(propsOf(h, 'llm'), {
        ...dataOf(h, 'llm'),
        'prompt_template': [
          {'id': 'a', 'role': 'system', 'text': 'A2'},
          {'id': 'c', 'role': 'assistant', 'text': 'C'},
          {'id': 'd', 'role': 'user', 'text': 'D'},
          {'id': 'b', 'role': 'user', 'text': 'B'},
        ],
      });
      await settle(t);
      final ids = [for (final i in (h['llm']!.config['prompt_template']! as VItems).items) i.id];
      // a and c keep their items; b moves (a new item: ids are never reused), d is new.
      expect(ids.take(2), ['a', 'c']);
      expect([for (final p in dataOf(h, 'llm')['prompt_template']! as List) (p as Map)['id']], ['a', 'c', 'd', 'b']);
      expect([for (final p in dataOf(h, 'llm')['prompt_template']! as List) (p as Map)['text']], ['A2', 'C', 'D', 'B']);
      await h.dispose(t);
    });
  });
}

/// Renders the group's panels to PNG files (at 2x, as on the device) for eyeballing the layout; only with
/// `SCREENSHOT_DIR` set: `SCREENSHOT_DIR=/tmp/shots flutter test test/node_panels_llm_test.dart`.
void screenshots() {
  final out = Platform.environment['SCREENSHOT_DIR'];
  if (out == null) return;

  Future<void> shoot(
    WidgetTester t,
    String name,
    List<(String, String, Map<String, Object?>)> chain, {
    LlmGroupServices services = LlmGroupServices.empty,
    bool chatMode = false,
    Future<void> Function()? before,
  }) async {
    await useAppFonts();
    await t.runAsync(() => DifyI18n.load('en-US'));
    final h = await startPanel(
      t,
      chain,
      services: services,
      chatMode: chatMode,
      screen: const Size(900, 1800),
      pump: false,
    );
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(900 * 2, 1800 * 2);
    final boundary = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: llmPanel(h, chain.last.$1, services: services, chatMode: chatMode),
      ),
    );
    await settle(t, 800);
    await before?.call();
    await settle(t, 400);
    await t.runAsync(() async {
      final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(out).createSync(recursive: true);
      File('$out/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    });
    await h.dispose(t);
  }

  testWidgets('screenshots', (t) async {
    const start = ('start', 'start', {'variables': <Object?>[]});
    const models = ModelCatalog(
      providers: [
        ModelProvider(provider: 'langgenius/openai/openai', label: {'en_US': 'OpenAI'}),
      ],
      modelLists: {
        ModelTypeEnum.textGeneration: [
          ProviderWithModels(
            provider: 'langgenius/openai/openai',
            label: {'en_US': 'OpenAI'},
            models: [
              ModelItem(
                model: 'gpt-4o',
                label: {'en_US': 'gpt-4o'},
                features: ['vision', 'structured-output', 'tool-call'],
                modelProperties: {'mode': 'chat', 'context_size': 128000},
              ),
            ],
          ),
        ],
      },
    );
    await shoot(
      t,
      'llm',
      [
        start,
        (
          'llm',
          'llm',
          {
            'model': {
              'provider': 'langgenius/openai/openai',
              'name': 'gpt-4o',
              'mode': 'chat',
              'completion_params': {'temperature': 0.7},
            },
            'prompt_template': [
              {'id': 'p1', 'role': 'system', 'text': 'You are a helpful assistant.'},
              {'id': 'p2', 'role': 'user', 'text': '{{#sys.query#}}'},
            ],
            'context': {'enabled': false, 'variable_selector': <String>[]},
            'vision': {'enabled': true},
            'memory': {
              'window': {'enabled': false, 'size': 50},
              'query_prompt_template': '{{#sys.query#}}\n\n{{#sys.files#}}',
            },
            'structured_output_enabled': true,
            'structured_output': {
              'schema': {
                'type': 'object',
                'properties': {
                  'answer': {'type': 'string', 'description': 'The answer'},
                  'score': {'type': 'number'},
                },
                'required': ['answer'],
                'additionalProperties': false,
              },
            },
          },
        ),
      ],
      services: const LlmGroupServices(models: models),
      chatMode: true,
      before: () async {
        await t.tap(find.textContaining('OUTPUT VARIABLES', findRichText: true));
      },
    );
    await shoot(
      t,
      'llm-schema',
      [
        start,
        (
          'llm',
          'llm',
          {
            'model': {
              'provider': 'langgenius/openai/openai',
              'name': 'gpt-4o',
              'mode': 'chat',
              'completion_params': {},
            },
            'prompt_template': [
              {'id': 'p1', 'role': 'system', 'text': ''},
            ],
            'context': {'enabled': false, 'variable_selector': <String>[]},
            'vision': {'enabled': false},
            'structured_output_enabled': true,
            'structured_output': {
              'schema': {
                'type': 'object',
                'properties': {
                  'answer': {'type': 'string', 'description': 'The answer'},
                  'items': {
                    'type': 'array',
                    'items': {
                      'type': 'object',
                      'properties': {
                        'name': {'type': 'string'},
                      },
                      'required': <String>[],
                      'additionalProperties': false,
                    },
                  },
                },
                'required': ['answer'],
                'additionalProperties': false,
              },
            },
          },
        ),
      ],
      services: const LlmGroupServices(models: models),
      before: () async {
        await t.tap(find.textContaining('OUTPUT VARIABLES', findRichText: true));
        await settle(t);
        await t.tap(find.text('Configure'));
        await settle(t);
        await t.tap(find.text('answer').last);
      },
    );
    await shoot(
      t,
      'agent',
      [
        start,
        (
          'agent',
          'agent',
          {
            'agent_strategy_provider_name': 'langgenius/agent/agent',
            'agent_strategy_name': 'function_calling',
            'agent_strategy_label': 'FunctionCalling',
            'plugin_unique_identifier': 'langgenius/agent:0.0.9',
            'meta': {'version': '0.0.9'},
            'tool_node_version': '2',
            'agent_parameters': {
              'query': {'type': 'constant', 'value': '{{#sys.query#}}'},
              'maximum_iterations': {'type': 'constant', 'value': 3},
            },
            'output_schema': <String, Object?>{},
          },
        ),
      ],
      services: LlmGroupServices(
        models: models,
        strategyProviders: [
          {
            'provider': 'langgenius/agent/agent',
            'plugin_unique_identifier': 'langgenius/agent:0.0.9',
            'plugin_id': 'langgenius/agent',
            'declaration': {
              'identity': {
                'name': 'langgenius/agent/agent',
                'label': {'en_US': 'Dify Agent Strategies'},
              },
              'strategies': [
                {
                  'identity': {
                    'name': 'function_calling',
                    'label': {'en_US': 'FunctionCalling'},
                  },
                  'features': ['history-messages'],
                  'parameters': [
                    {
                      'name': 'model',
                      'type': 'model-selector',
                      'scope': 'tool-call&llm',
                      'required': true,
                      'label': {'en_US': 'Model'},
                    },
                    {
                      'name': 'tools',
                      'type': 'array[tools]',
                      'required': true,
                      'label': {'en_US': 'Tools list'},
                      'help': {'en_US': 'Tools'},
                    },
                    {
                      'name': 'instruction',
                      'type': 'string',
                      'required': true,
                      'label': {'en_US': 'Instruction'},
                    },
                    {
                      'name': 'query',
                      'type': 'string',
                      'required': true,
                      'label': {'en_US': 'Query'},
                    },
                    {
                      'name': 'maximum_iterations',
                      'type': 'number',
                      'required': true,
                      'min': 1,
                      'max': 30,
                      'default': 3,
                      'label': {'en_US': 'Maximum Iterations'},
                    },
                  ],
                },
              ],
            },
            'meta': {'version': '0.0.9'},
          },
        ],
      ),
      chatMode: true,
    );
  });
}
