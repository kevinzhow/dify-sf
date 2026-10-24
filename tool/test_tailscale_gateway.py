"""The gateway is rendered from explicit origins, never arbitrary nginx text."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('gateway', Path(__file__).with_name('tailscale_gateway.py'))
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class GatewayTests(unittest.TestCase):
    def test_rejects_injected_configuration_and_non_origins(self):
        for origin in ('file:///etc/passwd', 'http://user:secret@host', 'http://host/path',
                       'http://host?x=1', 'http://host;include /etc/*', 'http://host\n}',
                       'http://$upstream', 'http://host#fragment'):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                gateway.render(origin, 19197)

    def test_proxy_and_browser_assets_share_one_loopback_gateway(self):
        value = gateway.render('http://127.0.0.1:19097/', 19197)
        self.assertIn('listen 127.0.0.1:19197;', value)
        self.assertIn('proxy_pass http://127.0.0.1:19097;', value)
        self.assertIn('types { application/javascript mjs; }', value)
        self.assertIn('proxy_buffering off;', value)
        self.assertIn('proxy_request_buffering off;', value)
        self.assertIn('proxy_set_header X-Forwarded-Proto https;', value)
        self.assertNotIn('__API_ORIGIN__', value)
        self.assertNotIn('__LISTEN_PORT__', value)

    def test_only_unprivileged_ports(self):
        for port in (0, 443, 65536):
            with self.assertRaises(ValueError):
                gateway.render('http://127.0.0.1:19097', port)


if __name__ == '__main__':
    unittest.main()
