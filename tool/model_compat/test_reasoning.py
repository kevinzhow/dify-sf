"""Run inside the isolated signed plugin's venv, with its package as cwd.

The compatibility image loads the host policy at Python startup. These tests use
Dify's actual lazy class loader and SDK validation; no vendor is contacted.
"""
import unittest
from dify_plugin.core.utils.class_loader import load_multi_subclasses_from_source
from dify_plugin.interfaces.model.ai_model import AIModel

class ReasoningCompatibilityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        classes = load_multi_subclasses_from_source(
            module_name='models.llm.llm', script_path='models/llm/llm.py', parent_type=AIModel,
        )
        cls.model = next(x for x in classes if x.__name__ == 'OpenAILargeLanguageModel')([])
        cls.credentials = {'api_type': 'responses', 'mode': 'chat', 'context_size': '4096',
                           'max_tokens_to_sample': '1024', 'agent_thought_support': 'only_thinking_supported'}

    def test_lazy_loader_accepts_future_levels_without_model_id_rules(self):
        for value in ['max', 'ultra', 'vendor-next-level']:
            actual = self.model._validate_and_filter_model_parameters(
                'arbitrary-service-alias', {'reasoning_effort': value}, self.credentials,
            )
            self.assertEqual(actual['reasoning_effort'], value)

    def test_provider_enum_overrides_recommendations_for_schema_and_invoke(self):
        credentials = self.credentials | {'_dify_sf_reasoning_levels': ['max', 'vendor-next-level']}
        schema = self.model.get_model_schema('arbitrary-service-alias', credentials)
        rule = next(p for p in schema.parameter_rules if p.name == 'reasoning_effort')
        self.assertEqual(rule.options, ['max', 'vendor-next-level'])
        with self.assertRaises(ValueError):
            self.model._validate_and_filter_model_parameters(
                'arbitrary-service-alias', {'reasoning_effort': 'not-declared'}, credentials,
            )

    def test_other_validation_and_input_dictionary_are_preserved(self):
        params = {'reasoning_effort': 'max', 'temperature': 0.5}
        result = self.model._validate_and_filter_model_parameters('arbitrary-service-alias', params, self.credentials)
        self.assertEqual(result, params)
        for invalid in [{'reasoning_effort': 42}, {'reasoning_effort': 'max', 'temperature': 999}]:
            with self.assertRaises(ValueError):
                self.model._validate_and_filter_model_parameters('arbitrary-service-alias', invalid, self.credentials)

    def test_official_reasoning_removes_sampling_for_default_and_selected_efforts(self):
        credentials = self.credentials | {'endpoint_url': 'https://api.openai.com/v1'}
        for effort in [None, 'low', 'high', 'xhigh', 'max']:
            with self.subTest(effort=effort):
                params = {'temperature': 0.7, 'top_p': 0.9, 'max_tokens': 128}
                if effort is not None:
                    params['reasoning_effort'] = effort
                before = dict(params)
                actual = self.model._validate_and_filter_model_parameters('gpt-6.1-terra', params, credentials)
                self.assertNotIn('temperature', actual)
                self.assertNotIn('top_p', actual)
                self.assertEqual(actual['max_tokens'], 128)
                self.assertEqual(actual.get('reasoning_effort'), effort)
                self.assertEqual(params, before)

    def test_none_preserves_sampling(self):
        credentials = self.credentials | {'endpoint_url': 'https://api.openai.com/v1/'}
        params = {'temperature': 0.7, 'top_p': 0.9, 'reasoning_effort': 'none'}
        self.assertEqual(self.model._validate_and_filter_model_parameters('gpt-6.1-terra', params, credentials), params)

    def test_actual_endpoint_and_effective_alias_control_policy(self):
        params = {'temperature': 0.7, 'reasoning_effort': 'max'}
        for endpoint in ['https://other.invalid/v1', 'https://api.openai.com.attacker.invalid/v1',
                         'http://api.openai.com/v1', 'https://api.openai.com/v1?proxy=1',
                         'https://user@api.openai.com/v1', 'https://api.openai.com:444/v1']:
            with self.subTest(endpoint=endpoint):
                credentials = self.credentials | {'endpoint_url': endpoint}
                self.assertEqual(self.model._validate_and_filter_model_parameters('gpt-6.1-terra', params, credentials), params)
        credentials = self.credentials | {'endpoint_url': 'https://api.openai.com/v1'}
        for name in ['gpt-4o', 'unknown-future-model']:
            self.assertEqual(self.model._validate_and_filter_model_parameters(name, params, credentials), params)
        aliased = credentials | {'endpoint_model_name': 'gpt-6.1-terra'}
        self.assertNotIn('temperature', self.model._validate_and_filter_model_parameters('display-alias', params, aliased))
        ordinary = credentials | {'endpoint_model_name': 'gpt-4o'}
        self.assertEqual(self.model._validate_and_filter_model_parameters('gpt-6.1-terra', params, ordinary), params)

    def test_real_responses_wire_excludes_sampling_without_contacting_a_provider(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        from dify_plugin.entities.model.message import UserPromptMessage
        class Captured(Exception):
            pass
        calls = []
        def create(**kwargs):
            calls.append(kwargs)
            raise Captured()
        client = SimpleNamespace(responses=SimpleNamespace(create=create))
        credentials = self.credentials | {'endpoint_url': 'https://api.openai.com/v1', 'api_key': 'fixture-only'}
        params = self.model._validate_and_filter_model_parameters('gpt-6.1-terra',
                    {'temperature': 0.7, 'top_p': 0.9, 'reasoning_effort': 'max', 'max_tokens': 128}, credentials)
        with patch.object(self.model, '_create_openai_client', return_value=client):
            with self.assertRaises(Captured):
                self.model._invoke('gpt-6.1-terra', credentials, [UserPromptMessage(content='hello')], params, stream=False)
        self.assertEqual(len(calls), 1)
        self.assertNotIn('temperature', calls[0])
        self.assertNotIn('top_p', calls[0])
        self.assertEqual(calls[0]['reasoning'], {'effort': 'max'})
        self.assertEqual(calls[0]['max_output_tokens'], 128)

if __name__ == '__main__':
    unittest.main()
