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

if __name__ == '__main__':
    unittest.main()
