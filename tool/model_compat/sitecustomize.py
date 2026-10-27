"""Loaded by the compatibility image's system Python sitecustomize hook.

Daemon 0.6.11 intentionally strips PYTHONPATH and daemon secrets from plugin
workers. Preserve that boundary; use a separate, image-owned startup module.
"""
try:
    from dify_plugin.interfaces.model.ai_model import AIModel
    from dify_plugin.interfaces.model.large_language_model import LargeLanguageModel
except ModuleNotFoundError as error:
    if error.name != 'dify_plugin':
        raise
else:
    import importlib.util
    spec = importlib.util.spec_from_file_location('dify_sf_reasoning', '/opt/dify-sf/model-compat/reasoning.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.install(AIModel, LargeLanguageModel)
