// dify-spec: web/app/components/workflow/nodes/llm/__tests__/default.spec.ts
import 'package:dify_sf_app/src/workflow_editor/header/checklist/node_validators.dart';
import 'package:flutter_test/flutter_test.dart';

/// `withSelectorKey((key) => key, 'workflow')`: the key, without namespace or parameters.
String t(String ns, String key, [Map<String, Object?> params = const {}]) => key;

const _defaultModel = {
  'provider': '',
  'name': '',
  'mode': 'chat',
  'completion_params': {'temperature': 0.7},
};

Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
  'type': 'llm',
  'model': {..._defaultModel, 'provider': 'langgenius/openai/gpt-4.1', 'mode': 'chat'},
  'prompt_template': [
    {'role': 'system', 'text': 'You are helpful.', 'edition_type': 'basic'},
  ],
  'context': {'enabled': false, 'variable_selector': <Object?>[]},
  'vision': {'enabled': false},
  ...overrides,
};

Map<String, Object?> _llmEnv(String mode) => {
  'id': 'env-1',
  'name': 'for_summarize',
  'value_type': 'llm',
  'value': {'provider': 'langgenius/anthropic/anthropic', 'name': 'claude-sonnet', 'mode': mode},
  'description': '',
};

const _memory = {
  'window': {'enabled': false, 'size': 10},
  'query_prompt_template': 'custom prompt',
};

void main() {
  group('llm default node validation', () {
    test('should require a model provider before validating the prompt', () {
      final error = checkValidLLM(
        createPayload({
          'model': {
            ..._defaultModel,
            'provider': '',
            'name': 'gpt-4.1',
            'mode': 'chat',
            'completion_params': {'temperature': 0.7},
          },
        }),
        t,
        null,
      );
      expect(error, 'errorMsg.fieldRequired');
    });

    test('should return a valid result when the provider and prompt are configured', () {
      expect(checkValidLLM(createPayload(), t, null), '');
    });

    test('should validate a configured LLM environment model reference', () {
      final error = checkValidLLM(
        createPayload({
          'model_selector': ['env', 'for_summarize'],
        }),
        t,
        {
          'environmentVariables': [_llmEnv('chat')],
        },
      );
      expect(error, '');
    });

    test('should reject a missing LLM environment model reference', () {
      final error = checkValidLLM(
        createPayload({
          'model_selector': ['env', 'missing'],
        }),
        t,
        {'environmentVariables': <Object?>[]},
      );
      expect(error, 'errorMsg.fieldRequired');
    });

    test('should preserve legacy non-environment model selectors as static models', () {
      final error = checkValidLLM(
        createPayload({
          'model_selector': ['start', 'MODEL_NAME'],
        }),
        t,
        {'environmentVariables': <Object?>[]},
      );
      expect(error, '');
    });

    test('should reject an LLM environment model whose mode differs from the node mode', () {
      final error = checkValidLLM(
        createPayload({
          'model_selector': ['env', 'for_summarize'],
        }),
        t,
        {
          'environmentVariables': [_llmEnv('completion')],
        },
      );
      expect(error, 'errorMsg.fieldRequired');
    });

    test('should require sys.query in memory user prompt outside snippet flows', () {
      final error = checkValidLLM(createPayload({'memory': _memory}), t, {'flowType': 'appFlow'});
      expect(error, 'nodes.llm.sysQueryInUser');
    });

    test('should not require sys.query in memory user prompt for snippet flows', () {
      final error = checkValidLLM(createPayload({'memory': _memory}), t, {'flowType': 'snippet'});
      expect(error, '');
    });
  });
}
