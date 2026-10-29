"""Host compatibility policy for arbitrary OpenAI-compatible reasoning levels.

Signed plugin packages and their SDK files are never modified. Keep the plugin's
recommendations for schema RPCs. When the provider declares its own enum, use it
in both metadata and validation. Otherwise let the provider validate new levels.
"""
from functools import lru_cache, wraps
import hashlib
import inspect
from pathlib import Path
from urllib.parse import urlsplit

PINNED_LLM_SHA256 = '2f1a5493116f350ad34d12a2243ca8df9bd4c499b5f04de9749bfcc137affb9d'
LEVELS_KEY = '_dify_sf_reasoning_levels'


@lru_cache(maxsize=32)
def compatible(cls):
    if cls.__module__ != 'models.llm.llm' or cls.__name__ != 'OpenAILargeLanguageModel':
        return False
    try:
        # The SDK's lazy loader does not always register its dynamic class in
        # sys.modules. Function code retains the actual source path in both
        # normal imports and that loader; inspect.getfile(cls) does not.
        source = inspect.unwrap(cls._invoke).__code__.co_filename
        return hashlib.sha256(Path(source).read_bytes()).hexdigest() == PINNED_LLM_SHA256
    except (OSError, TypeError):
        return False


def levels(credentials):
    value = credentials.get(LEVELS_KEY)
    if (isinstance(value, list) and 0 < len(value) <= 100
            and all(isinstance(x, str) and x and len(x) <= 128
                    and not any(ord(c) < 32 or ord(c) == 127 for c in x) for x in value)):
        return list(dict.fromkeys(value))
    return None



# Official model compatibility, checked 2026-10-29 against:
# https://developers.openai.com/api/docs/guides/latest-model
# https://developers.openai.com/api/docs/models/gpt-6.1-terra
# Sampling is unavailable when these models reason (including their default).
# Exact endpoint and effective model checks keep compatible services independent.
_OFFICIAL_REASONING_MODELS = frozenset({
    'gpt-6-astra', 'gpt-6-sol', 'gpt-6-luna', 'gpt-6.1-sol', 'gpt-6.1-terra',
})
_SAMPLING_PARAMETERS = frozenset({'temperature', 'top_p', 'top_logprobs', 'logprobs'})


def official_reasoning(model, credentials, parameters):
    try:
        endpoint = urlsplit(credentials.get('endpoint_url', ''))
        official = (endpoint.scheme == 'https' and endpoint.hostname == 'api.openai.com'
                    and endpoint.port in (None, 443) and endpoint.username is None
                    and endpoint.password is None and not endpoint.query and not endpoint.fragment
                    and endpoint.path in ('/v1', '/v1/'))
    except (TypeError, ValueError, AttributeError):
        return False
    effective_model = credentials.get('endpoint_model_name') or model
    return (official and isinstance(effective_model, str) and effective_model in _OFFICIAL_REASONING_MODELS
            and parameters.get('reasoning_effort') != 'none')


def supported_parameters(model, credentials, parameters):
    if not official_reasoning(model, credentials, parameters):
        return parameters
    return {key: value for key, value in parameters.items() if key not in _SAMPLING_PARAMETERS}


def install(ai_model_class, llm_class):
    original_schema = ai_model_class._get_customizable_model_schema
    if getattr(original_schema, '_dify_sf_reasoning', False):
        return

    @wraps(original_schema)
    def schema(self, model, credentials, *args, **kwargs):
        value = original_schema(self, model, credentials, *args, **kwargs)
        declared = levels(credentials)
        if value is None or declared is None or not compatible(type(self)):
            return value
        result = value.model_copy(deep=True)
        for rule in result.parameter_rules:
            if rule.name == 'reasoning_effort':
                rule.options = declared
        return result

    original_validate = llm_class._validate_and_filter_model_parameters

    @wraps(original_validate)
    def validate(self, model, model_parameters, credentials):
        effort = model_parameters.get('reasoning_effort')
        if effort is None or not compatible(type(self)) or levels(credentials) is not None:
            return supported_parameters(model, credentials, original_validate(self, model, model_parameters, credentials))
        if not any(rule.name == 'reasoning_effort' for rule in self.get_parameter_rules(model, credentials)):
            return supported_parameters(model, credentials, original_validate(self, model, model_parameters, credentials))
        if (not isinstance(effort, str) or not effort or len(effort) > 128
                or any(ord(c) < 32 or ord(c) == 127 for c in effort)):
            raise ValueError('Model Parameter reasoning_effort must be a non-empty string of at most 128 characters.')
        # Delegate every other field to the original validator. Do not mutate the
        # input dictionary or a shared schema, and never map one level to another.
        other = {k: v for k, v in model_parameters.items() if k != 'reasoning_effort'}
        result = original_validate(self, model, other, credentials)
        result['reasoning_effort'] = effort
        return supported_parameters(model, credentials, result)

    schema._dify_sf_reasoning = True
    ai_model_class._get_customizable_model_schema = schema
    llm_class._validate_and_filter_model_parameters = validate
