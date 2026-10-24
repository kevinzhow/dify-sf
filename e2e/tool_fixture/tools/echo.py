import time
from dify_plugin import Tool
from dify_plugin.entities import ParameterOption
from dify_plugin.entities.tool import ToolParameter

class Echo(Tool):
    def _get_runtime_parameters(self):
        label = 'First prompt' if self.runtime.credentials.get('api_key') == 'fixture-one' else 'Second prompt'
        return [ToolParameter.model_validate({
            'name': 'prompt', 'label': {'en_US': label}, 'human_description': {'en_US': 'Text to return'},
            'type': 'string', 'form': 'llm', 'required': True,
        }), ToolParameter.model_validate({
            'name': 'mode', 'label': {'en_US': 'Mode'}, 'human_description': {'en_US': 'Result mode'},
            'type': 'dynamic-select', 'form': 'form', 'default': 'normal',
        })]

    def _fetch_parameter_options(self, parameter):
        identity = 'one' if self.runtime.credentials.get('api_key') == 'fixture-one' else 'two'
        return [ParameterOption(value=v, label={'en_US': identity + ':' + v}) for v in ('normal', 'file', 'reject', 'slow')]

    def _invoke(self, tool_parameters):
        if self.runtime.credentials.get('api_key') not in ('fixture-one', 'fixture-two'):
            raise ValueError('Fixture refused credentials')
        mode = tool_parameters.get('mode', 'normal')
        if mode == 'reject':
            raise ValueError('Fixture refused invocation')
        if mode == 'slow':
            time.sleep(20)
        prompt = tool_parameters['prompt']
        yield self.create_text_message(prompt)
        yield self.create_json_message({'echo': prompt, 'credential': 'one' if self.runtime.credentials['api_key'] == 'fixture-one' else 'two'})
        yield self.create_stream_variable_message('answer', 'first ')
        yield self.create_stream_variable_message('answer', 'second')
        if mode == 'file':
            yield self.create_blob_message(b'controlled file output\n', {'mime_type': 'text/plain', 'filename': 'fixture.txt'})
