// dify-spec: web/app/components/workflow/nodes/llm/__tests__/utils.spec.ts
// dify-spec: web/app/components/workflow/nodes/llm/hooks/__tests__/use-llm-input-manager.spec.ts
// dify-spec: web/app/components/workflow/nodes/llm/hooks/__tests__/use-llm-prompt-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/llm/hooks/__tests__/use-llm-structured-output-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/llm/__tests__/use-config.spec.ts
//
// The LLM's logic as ported to llm_config.dart: Dify's hooks become classes over the node data and a setInputs
// callback (the spec's mocked setInputs records the calls and moves inputRef). use-config's composition of mocked
// hooks is checked on the real handlers instead; the default-model hydration runs in the panel.
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_config.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_picker_model.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_vars.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _context = '{{#context#}}', _history = '{{#histories#}}', _query = '{{#query#}}';

Map<String, Object?> _payload([Map<String, Object?> overrides = const {}]) => {
  'type': 'llm',
  'title': 'LLM',
  'desc': '',
  'model': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat', 'completion_params': <String, Object?>{}},
  'prompt_template': [
    {'role': 'system', 'text': 'You are helpful.', 'edition_type': 'basic'},
  ],
  'context': {'enabled': false, 'variable_selector': <String>[]},
  'vision': {'enabled': false},
  ...overrides,
};

const _defaultConfig = {
  'prompt_templates': {
    'chat_model': {
      'prompts': [
        {'role': 'system', 'text': 'Default chat prompt', 'edition_type': 'basic'},
      ],
    },
    'completion_model': {
      'prompt': {'role': 'user', 'text': 'Default completion prompt', 'edition_type': 'basic'},
      'conversation_histories_role': {'user_prefix': 'USER', 'assistant_prefix': 'ASSISTANT'},
    },
  },
};

/// A prompt config over a moving inputRef; the calls are recorded.
({LlmPromptConfig config, List<Map<String, Object?>> calls}) _promptConfig(
  Map<String, Object?> inputs, {
  bool isChatMode = true,
  bool isChatModel = true,
}) {
  var ref = inputs;
  final calls = <Map<String, Object?>>[];
  return (
    config: LlmPromptConfig(
      inputsOf: () => ref,
      setInputs: (n) {
        calls.add(n);
        ref = n;
      },
      isChatMode: isChatMode,
      isChatModel: isChatModel,
    ),
    calls: calls,
  );
}

PickerVar _var(String type) => PickerVar('v', type);

void main() {
  setUp(useDifyTestTranslator);

  group('llm utils', () {
    group('getLLMModelIssue', () {
      test('returns provider-required when the model provider is missing', () {
        expect(getLLMModelIssue(modelProvider: null), LLMModelIssueCode.providerRequired);
      });

      test('returns provider-plugin-unavailable when the provider plugin is not installed', () {
        expect(
          getLLMModelIssue(modelProvider: 'langgenius/openai/gpt-4.1', isModelProviderInstalled: false),
          LLMModelIssueCode.providerPluginUnavailable,
        );
      });

      test('returns null when the provider is present and installed', () {
        expect(getLLMModelIssue(modelProvider: 'langgenius/openai/gpt-4.1', isModelProviderInstalled: true), isNull);
      });
    });

    group('isLLMModelProviderInstalled', () {
      test('returns true when the model provider is missing', () {
        expect(isLLMModelProviderInstalled(null, {}), isTrue);
      });

      test('matches installed plugin ids using the provider plugin prefix', () {
        expect(isLLMModelProviderInstalled('langgenius/openai/gpt-4.1', {'langgenius/openai'}), isTrue);
      });

      test('returns false when the provider plugin id is not installed', () {
        expect(isLLMModelProviderInstalled('langgenius/openai/gpt-4.1', {'langgenius/anthropic'}), isFalse);
      });
    });

    group('environment model resolution', () {
      const model = {
        'provider': 'direct-provider',
        'name': 'direct-model',
        'mode': 'chat',
        'completion_params': {'temperature': 0.3},
      };
      Map<String, Object?> env(Map<String, Object?> value, {String valueType = 'llm'}) => {
        'id': 'env-1',
        'name': 'for_summarize',
        'value_type': valueType,
        'value': value,
        'description': '',
      };
      final environmentVariables = <Object?>[
        env({
          'provider': 'shared-provider',
          'name': 'shared-model',
          'mode': 'chat',
          'completion_params': {'temperature': 0.8},
        }),
      ];

      test('uses shared completion params while resolving the shared model', () {
        expect(resolveLLMNodeModel(model, ['env', 'for_summarize'], environmentVariables), {
          'provider': 'shared-provider',
          'name': 'shared-model',
          'mode': 'chat',
          'completion_params': {'temperature': 0.8},
        });
      });

      test('keeps node completion params for a legacy shared model without params', () {
        final legacy = <Object?>[
          env({'provider': 'shared-provider', 'name': 'shared-model', 'mode': 'chat'}),
        ];
        expect(resolveLLMNodeModel(model, ['env', 'for_summarize'], legacy), {
          'provider': 'shared-provider',
          'name': 'shared-model',
          'mode': 'chat',
          'completion_params': {'temperature': 0.3},
        });
      });

      test('returns the environment identity for initial binding before the node mode is updated', () {
        final completion = [
          env({
            'provider': 'shared-provider',
            'name': 'shared-completion-model',
            'mode': 'completion',
            'completion_params': {'temperature': 0.8},
          }),
        ];
        expect(getLLMEnvironmentModel(['env', 'for_summarize'], completion), {
          'provider': 'shared-provider',
          'name': 'shared-completion-model',
          'mode': 'completion',
          'completion_params': {'temperature': 0.8},
        });
      });

      test('rejects a live reference when its mode no longer matches the stored node mode', () {
        final changed = <Object?>[
          env({'provider': 'shared-provider', 'name': 'shared-model', 'mode': 'completion'}),
        ];
        expect(resolveLLMNodeModel(model, ['env', 'for_summarize'], changed), isNull);
      });

      test('returns undefined for a missing or non-LLM environment variable', () {
        expect(resolveLLMNodeModel(model, ['env', 'missing'], <Object?>[...environmentVariables]), isNull);
        final stringVar = <Object?>[
          env((environmentVariables.first! as Map)['value']! as Map<String, Object?>, valueType: 'string'),
        ];
        expect(resolveLLMNodeModel(model, ['env', 'for_summarize'], stringVar), isNull);
      });

      test('keeps the static model for a legacy non-environment selector', () {
        const selector = ['start', 'MODEL_NAME'];
        expect(isEnvironmentModelSource(selector), isFalse);
        expect(resolveLLMNodeModel(model, selector, environmentVariables), model);
      });

      test('keeps the static model when the persisted selector is null', () {
        expect(isEnvironmentModelSource(null), isFalse);
        expect(resolveLLMNodeModel(model, null, environmentVariables), model);
      });
    });
  });

  group('use-llm-input-manager', () {
    test('ignores default configs that do not define prompt templates', () {
      final calls = <Map<String, Object?>>[];
      final manager = LlmInputManager(inputs: _payload(), doSetInputs: calls.add, defaultConfig: {}, isChatModel: true);
      final draft = _payload();
      manager.appendDefaultPromptConfig(draft, {});
      expect(draft['prompt_template'], _payload()['prompt_template']);
      expect(calls, isEmpty);
    });

    test('hydrates the default chat prompt when the payload has no prompt template', () {
      final calls = <Map<String, Object?>>[];
      LlmInputManager(
        inputs: _payload()..remove('prompt_template'),
        doSetInputs: calls.add,
        defaultConfig: _defaultConfig,
        isChatModel: true,
      ).hydrate();
      expect(calls.single['prompt_template'], (_defaultConfig['prompt_templates']!['chat_model']! as Map)['prompts']);
    });

    test('applies completion defaults and injects the default role prefix when memory has none', () {
      final calls = <Map<String, Object?>>[];
      final completionModel = {
        'provider': 'openai',
        'name': 'gpt-4o-mini',
        'mode': 'completion',
        'completion_params': {},
      };
      final manager = LlmInputManager(
        inputs: _payload({'model': completionModel}),
        doSetInputs: calls.add,
        defaultConfig: _defaultConfig,
        isChatModel: false,
      );
      final draft = _payload({'model': completionModel});
      manager.appendDefaultPromptConfig(draft, _defaultConfig, false);
      manager.setInputs(
        _payload({
          'model': completionModel,
          'prompt_template': draft['prompt_template'],
          'memory': {
            'window': {'enabled': true, 'size': 8},
            'query_prompt_template': '{{#sys.query#}}',
          },
        }),
      );
      expect(
        calls.last['prompt_template'],
        (_defaultConfig['prompt_templates']!['completion_model']! as Map)['prompt'],
      );
      expect((calls.last['memory']! as Map)['role_prefix'], {'user': 'USER', 'assistant': 'ASSISTANT'});
    });

    test('passes inputs through unchanged when memory already has a role prefix or is absent', () {
      final calls = <Map<String, Object?>>[];
      final manager = LlmInputManager(
        inputs: _payload(),
        doSetInputs: calls.add,
        defaultConfig: _defaultConfig,
        isChatModel: true,
      );
      final withoutMemory = _payload();
      final withPrefix = _payload({
        'memory': {
          'role_prefix': {'user': 'U', 'assistant': 'A'},
          'window': {'enabled': false, 'size': 10},
          'query_prompt_template': '{{#sys.query#}}',
        },
      });
      manager
        ..setInputs(withoutMemory)
        ..setInputs(withPrefix);
      expect(identical(calls[0], withoutMemory), isTrue);
      expect(identical(calls[1], withPrefix), isTrue);
    });
  });

  group('use-llm-prompt-config', () {
    Map<String, Object?> base([Map<String, Object?> o = const {}]) => _payload({
      'prompt_template': [
        {'role': 'system', 'text': 'Base prompt', 'edition_type': 'basic'},
      ],
      'prompt_config': {'jinja2_variables': <Object?>[]},
      ...o,
    });

    test('initializes prompt config storage when it is missing or incomplete', () {
      final missing = _promptConfig(
        base({
          'prompt_template': [
            {'role': 'user', 'text': 'Template', 'edition_type': 'jinja2', 'jinja2_text': '{{ city }}'},
          ],
        })..remove('prompt_config'),
      );
      missing.config.handleAddEmptyVariable();
      expect(missing.calls.single['prompt_config'], {
        'jinja2_variables': [
          {'variable': '', 'value_selector': <String>[]},
        ],
      });

      final noVariables = _promptConfig(
        base({
          'prompt_template': [
            {'role': 'user', 'text': 'Template', 'edition_type': 'jinja2', 'jinja2_text': '{{ budget }}'},
          ],
          'prompt_config': <String, Object?>{},
        }),
      );
      noVariables.config.handleAddVariable({
        'variable': 'budget',
        'value_selector': ['start', 'budget'],
      });
      expect(noVariables.calls.single['prompt_config'], {
        'jinja2_variables': [
          {
            'variable': 'budget',
            'value_selector': ['start', 'budget'],
          },
        ],
      });
    });

    test('derives chat prompt status and filters the supported variable types', () {
      final (:config, calls: _) = _promptConfig(
        base({
          'prompt_template': [
            {'role': 'system', 'text': 'Question: $_query', 'edition_type': 'basic'},
            {'role': 'user', 'text': 'Template', 'edition_type': 'jinja2', 'jinja2_text': '{{ old_name }}'},
          ],
          'context': {'enabled': true, 'variable_selector': <String>[]},
        }),
      );
      expect(config.hasSetBlockStatus, (history: false, query: true, context: false));
      expect(config.shouldShowContextTip, isTrue);
      expect(config.isShowVars, isTrue);
      expect(filterInputVar(_var(VarType.string), const []), isTrue);
      expect(filterInputVar(_var(VarType.boolean), const []), isFalse);
      expect(filterJinja2InputVar(_var(VarType.object), const []), isTrue);
      expect(filterJinja2InputVar(_var(VarType.file), const []), isFalse);
      expect(filterMemoryPromptVar(_var(VarType.arrayObject), const []), isTrue);
      expect(filterMemoryPromptVar(_var(VarType.boolean), const []), isFalse);
    });

    test('updates variables, context, prompt, and memory for chat prompts', () {
      final (:config, :calls) = _promptConfig(
        base({
          'prompt_template': [
            {'role': 'user', 'text': 'Template', 'edition_type': 'jinja2', 'jinja2_text': '{{ old_name }}'},
          ],
          'prompt_config': {
            'jinja2_variables': [
              {
                'variable': 'old_name',
                'value_selector': ['start', 'old_name'],
              },
            ],
          },
        }),
      );
      config
        ..handleAddEmptyVariable()
        ..handleAddVariable({
          'variable': 'budget',
          'value_selector': ['start', 'budget'],
        })
        ..handleVarListChange([
          {
            'variable': 'city',
            'value_selector': ['start', 'city'],
          },
        ])
        ..handleVarNameChange('old_name', 'new_name')
        ..handleContextVarChange(['start', 'sys.query'])
        ..handleContextVarChange([])
        ..handlePromptChange([
          {'role': 'system', 'text': 'Updated prompt', 'edition_type': 'basic'},
        ])
        ..handleSyeQueryChange('{{#sys.query#}}')
        ..handleSyeQueryChange('custom query')
        ..handleMemoryChange({
          'window': {'enabled': true, 'size': 6},
          'query_prompt_template': 'saved memory',
        });
      List<Object?> vars(int i) => (calls[i]['prompt_config']! as Map)['jinja2_variables']! as List;
      expect(vars(0), hasLength(2));
      expect(vars(1), [
        {
          'variable': 'old_name',
          'value_selector': ['start', 'old_name'],
        },
        {'variable': '', 'value_selector': <String>[]},
        {
          'variable': 'budget',
          'value_selector': ['start', 'budget'],
        },
      ]);
      expect(vars(2), [
        {
          'variable': 'city',
          'value_selector': ['start', 'city'],
        },
      ]);
      expect(((calls[3]['prompt_template']! as List).first as Map)['jinja2_text'], '{{ new_name }}');
      expect(calls[4]['context'], {
        'enabled': true,
        'variable_selector': ['start', 'sys.query'],
      });
      expect(calls[5]['context'], {'enabled': false, 'variable_selector': <String>[]});
      expect(calls[6]['prompt_template'], [
        {'role': 'system', 'text': 'Updated prompt', 'edition_type': 'basic'},
      ]);
      expect(calls[7]['memory'], {
        'window': {'enabled': false, 'size': 10},
        'query_prompt_template': '{{#sys.query#}}',
      });
      expect((calls[8]['memory']! as Map)['query_prompt_template'], 'custom query');
      expect(calls[9]['memory'], {
        'window': {'enabled': true, 'size': 6},
        'query_prompt_template': 'saved memory',
      });
    });

    test('handles completion prompt branches, including the non-jinja early return and jinja rename flow', () {
      const completion = {'provider': 'openai', 'name': 'gpt-4o-mini', 'mode': 'completion', 'completion_params': {}};
      final basic = _promptConfig(
        base({
          'model': completion,
          'prompt_template': {'role': 'user', 'text': '$_context $_history $_query', 'edition_type': 'basic'},
        }),
        isChatModel: false,
      );
      expect(basic.config.hasSetBlockStatus, (history: true, query: true, context: true));
      expect(basic.config.shouldShowContextTip, isFalse);
      expect(basic.config.isShowVars, isFalse);
      basic.config.handleVarNameChange('old_name', 'new_name');
      expect((basic.calls.single['prompt_template']! as Map)['text'], '$_context $_history $_query');

      final jinja = _promptConfig(
        base({
          'model': completion,
          'prompt_template': {
            'role': 'user',
            'text': 'Template',
            'edition_type': 'jinja2',
            'jinja2_text': '{{ old_name }}',
          },
        }),
        isChatMode: false,
        isChatModel: false,
      );
      jinja.config.handleVarNameChange('old_name', 'budget');
      expect((jinja.calls.single['prompt_template']! as Map)['jinja2_text'], '{{ budget }}');
    });
  });

  group('use-llm-structured-output-config', () {
    ProviderWithModels provider(String name, String model, List<String> features) => ProviderWithModels(
      provider: name,
      label: {'en_US': name},
      models: [
        ModelItem(model: model, label: {'en_US': model}, modelType: 'llm', features: features),
      ],
    );

    test('detects supported models and updates structured output state', () {
      var ref = _payload();
      final calls = <Map<String, Object?>>[];
      final deleted = <String>[];
      final config = LlmStructuredOutputConfig(
        id: 'llm-node',
        inputsOf: () => ref,
        setInputs: (n) {
          calls.add(n);
          ref = n;
        },
        deleteNodeInspectorVars: deleted.add,
      );
      expect(
        isModelSupportStructuredOutput(
          [
            provider('openai', 'gpt-4o', [ModelFeatureEnum.structuredOutput]),
          ],
          'openai',
          'gpt-4o',
        ),
        isTrue,
      );
      expect(config.structuredOutputCollapsed, isTrue);
      config.handleStructureOutputEnableChange(true);
      expect(calls[0]['structured_output_enabled'], isTrue);
      expect(config.structuredOutputCollapsed, isFalse);
      expect(deleted, ['llm-node']);
      final output = {
        'schema': {
          'type': 'object',
          'properties': {
            'answer': {'type': 'string'},
          },
          'additionalProperties': false,
        },
      };
      config
        ..handleStructureOutputChange(output)
        ..handleReasoningFormatChange('separated')
        ..handleStructureOutputEnableChange(false);
      expect(calls[1]['structured_output'], output);
      expect(calls[2]['reasoning_format'], 'separated');
      expect(calls[3]['structured_output_enabled'], isFalse);
    });

    test('returns undefined support when the model is missing from the list', () {
      expect(isModelSupportStructuredOutput([provider('anthropic', 'claude', const [])], 'openai', 'gpt-4o'), isNull);
    });
  });

  group('llm/use-config', () {
    ({LlmModelConfig config, List<Map<String, Object?>> calls, List<bool> changed}) modelConfig(
      Map<String, Object?> inputs, {
      List<Object?> env = const [],
      Map<String, Object?>? defaultConfig,
    }) {
      final calls = <Map<String, Object?>>[];
      final changed = <bool>[];
      late LlmInputManager manager;
      manager = LlmInputManager(
        inputs: inputs,
        doSetInputs: calls.add,
        defaultConfig: defaultConfig,
        isChatModel: jsMap(inputs['model'])['mode'] == 'chat',
      );
      return (
        config: LlmModelConfig(manager: manager, environmentVariables: env, onModelChanged: () => changed.add(true)),
        calls: calls,
        changed: changed,
      );
    }

    const completionDefaults = {
      'prompt_templates': {
        'chat_model': {'prompts': <Object?>[]},
        'completion_model': {
          'prompt': {'text': 'default completion prompt'},
          'conversation_histories_role': {'user_prefix': 'User', 'assistant_prefix': 'Assistant'},
        },
      },
    };

    test('composes the helper hooks, forwards filterVar to available vars, and updates completion params', () {
      final (:config, :calls, :changed) = modelConfig(
        _payload({
          'model': {
            'provider': 'openai',
            'name': 'gpt-4o',
            'mode': 'chat',
            'completion_params': {'temperature': 0.7},
          },
          'prompt_template': <Object?>[],
        }),
        defaultConfig: completionDefaults,
      );
      config
        ..handleCompletionParamsChange({'top_p': 0.5})
        ..handleModelChanged((provider: 'openai', modelId: 'gpt-4.1', mode: 'chat'), {'temperature': 0.3});
      expect((calls[0]['model']! as Map)['completion_params'], {'top_p': 0.5});
      expect(calls[1]['model'], {
        'provider': 'openai',
        'name': 'gpt-4.1',
        'mode': 'chat',
        'completion_params': {'temperature': 0.3},
      });
      // Same mode: the default prompt is not appended.
      expect(calls[1]['prompt_template'], <Object?>[]);
      expect(changed, [true]);
    });

    testWidgets(
      'hydrates the model from the current provider, appends mode-specific defaults, and triggers the vision follow-up effect',
      (t) async {
        final services = LlmGroupServices(
          models: const ModelCatalog(
            modelLists: {
              ModelTypeEnum.textGeneration: [
                ProviderWithModels(
                  provider: 'anthropic',
                  label: {'en_US': 'Anthropic'},
                  models: [
                    ModelItem(
                      model: 'claude-sonnet',
                      label: {'en_US': 'claude-sonnet'},
                      modelType: 'llm',
                      modelProperties: {'mode': 'chat'},
                    ),
                  ],
                ),
              ],
            },
          ),
          defaultModels: const {
            ModelTypeEnum.textGeneration: (provider: 'anthropic', model: 'claude-sonnet', mode: 'chat'),
          },
          nodesDefaultConfigs: const {
            'llm': {
              'prompt_templates': {
                'chat_model': {
                  'prompts': [
                    {'role': 'system', 'text': 'default chat prompt'},
                  ],
                },
                'completion_model': {
                  'prompt': {'text': 'default completion prompt'},
                  'conversation_histories_role': {'user_prefix': 'User', 'assistant_prefix': 'Assistant'},
                },
              },
            },
          },
        );
        final h = await startPanel(t, [
          (
            'llm',
            'llm',
            _payload({
              'model': {'provider': '', 'name': '', 'mode': 'completion', 'completion_params': <String, Object?>{}},
              'vision': {'enabled': true},
            }),
          ),
        ], services: services);
        final d = dataOf(h, 'llm');
        expect(d['model'], containsPair('provider', 'anthropic'));
        expect(d['model'], containsPair('name', 'claude-sonnet'));
        expect(d['model'], containsPair('mode', 'chat'));
        // The default chat prompt (ConfigPrompt then gives it an id, as Dify's sortable list does).
        final prompts = d['prompt_template']! as List;
        expect(prompts, hasLength(1));
        expect(prompts.single, allOf(containsPair('role', 'system'), containsPair('text', 'default chat prompt')));
        // The vision follow-up: claude-sonnet has no vision, so vision goes off.
        expect(d['vision'], {'enabled': false});
        await h.dispose(t);
      },
    );

    test('resolves a referenced environment model with its shared completion params', () {
      final model = effectiveLlmModel(
        _payload({
          'model_selector': ['env', 'for_summarize'],
          'model': {
            'provider': 'cached-provider',
            'name': 'cached-model',
            'mode': 'chat',
            'completion_params': {'temperature': 0.2},
          },
        }),
        [
          {
            'id': 'env-1',
            'name': 'for_summarize',
            'value_type': 'llm',
            'value': {
              'provider': 'shared-provider',
              'name': 'shared-model',
              'mode': 'chat',
              'completion_params': {'temperature': 0.8},
            },
            'description': '',
          },
        ],
      );
      expect(model, {
        'provider': 'shared-provider',
        'name': 'shared-model',
        'mode': 'chat',
        'completion_params': {'temperature': 0.8},
      });
      expect(isEnvironmentModelSource(['env', 'for_summarize']), isTrue);
    });

    test('copies a newly bound environment identity and applies mode-specific prompt defaults', () {
      final (:config, :calls, changed: _) = modelConfig(
        _payload({
          'model': {
            'provider': 'openai',
            'name': 'gpt-4o',
            'mode': 'chat',
            'completion_params': {'temperature': 0.7},
          },
        }),
        env: [
          {
            'id': 'env-1',
            'name': 'for_research',
            'value_type': 'llm',
            'value': {
              'provider': 'shared-provider',
              'name': 'shared-completion-model',
              'mode': 'completion',
              'completion_params': {'top_p': 0.9},
            },
            'description': '',
          },
        ],
        defaultConfig: completionDefaults,
      );
      config.handleModelSelectorChange(['env', 'for_research'], {'max_tokens': 42});
      expect(calls.single['model_selector'], ['env', 'for_research']);
      expect(calls.single['model'], {
        'provider': 'shared-provider',
        'name': 'shared-completion-model',
        'mode': 'completion',
        'completion_params': {'top_p': 0.9},
      });
      expect(calls.single['prompt_template'], {'text': 'default completion prompt'});
    });

    test('switches back to direct input with the latest resolved environment identity', () {
      final (:config, :calls, changed: _) = modelConfig(
        _payload({
          'model_selector': ['env', 'for_summarize'],
          'model': {
            'provider': 'cached-provider',
            'name': 'cached-model',
            'mode': 'chat',
            'completion_params': {'temperature': 0.4},
          },
        }),
        env: [
          {
            'id': 'env-1',
            'name': 'for_summarize',
            'value_type': 'llm',
            'value': {
              'provider': 'latest-provider',
              'name': 'latest-model',
              'mode': 'chat',
              'completion_params': {'temperature': 0.8},
            },
            'description': '',
          },
        ],
      );
      config.handleModelSourceChange(false);
      expect(calls.single['model'], {
        'provider': 'latest-provider',
        'name': 'latest-model',
        'mode': 'chat',
        'completion_params': {'temperature': 0.8},
      });
      expect(calls.single.containsKey('model_selector'), isTrue);
      expect(calls.single['model_selector'], isNull);
    });
  });
}
