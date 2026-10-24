from dify_plugin import ToolProvider

class FiveProvider(ToolProvider):
    def _validate_credentials(self, credentials):
        if credentials.get('api_key') not in ('fixture-one', 'fixture-two'):
            raise ValueError('Fixture refused credentials')
