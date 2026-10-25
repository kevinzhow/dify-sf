import pathlib
import unittest

from prepare_runtime_proxy_allowlist import prepare

CONFIG = (pathlib.Path(__file__).resolve().parents[1] / 'docker/ssrf_proxy/squid.conf').read_text()


class RuntimeProxyProposalTests(unittest.TestCase):
    def test_exact_intersection_preserves_all_default_denials(self):
        result = prepare(CONFIG, '172.22.0.4', '100.100.10.1', 8443)
        self.assertIn('src 172.22.0.4/32', result)
        self.assertIn('dst 100.100.10.1/32', result)
        self.assertIn('acl approved_runtime_port port 8443', result)
        rule = 'http_access allow approved_runtime_client approved_runtime_host approved_runtime_port'
        self.assertLess(result.index('http_access deny !Safe_ports'), result.index(rule))
        self.assertLess(result.index(rule), result.index('http_access deny CONNECT !SSL_ports'))
        self.assertLess(result.index(rule), result.index('http_access deny to_private_networks'))
        self.assertEqual(result.count('http_access deny all'), CONFIG.count('http_access deny all'))
        self.assertEqual(result.count('acl SSL_ports port 443'), CONFIG.count('acl SSL_ports port 443'))
        self.assertNotIn('acl SSL_ports port 8443', result)

    def test_refuses_networks_hostnames_public_loopback_and_unsafe_ports(self):
        for client, destination, port in [
            ('172.22.0.0/16', '100.100.10.1', 8443), ('0.0.0.0', '100.100.10.1', 8443),
            ('127.0.0.1', '100.100.10.1', 8443), ('8.8.8.8', '100.100.10.1', 8443),
            ('172.22.0.4', '100.64.0.0/10', 8443), ('172.22.0.4', 'example.test', 8443),
            ('172.22.0.4', '127.0.0.1', 8443), ('172.22.0.4', '192.168.1.2', 8443),
            ('172.22.0.4', '8.8.8.8', 8443), ('172.22.0.4', '100.100.10.1', 22),
            ('172.22.0.4', '100.100.10.1', 0), ('172.22.0.4', '100.100.10.1', 65536),
        ]:
            with self.subTest(client=client, destination=destination, port=port):
                with self.assertRaises(ValueError):
                    prepare(CONFIG, client, destination, port)

    def test_requires_known_policy_and_refuses_duplicate_exceptions(self):
        with self.assertRaises(ValueError):
            prepare(CONFIG.replace('http_access deny CONNECT !SSL_ports', ''), '172.22.0.4', '100.100.10.1', 8443)
        with self.assertRaises(ValueError):
            prepare(prepare(CONFIG, '172.22.0.4', '100.100.10.1', 8443), '172.22.0.4', '100.100.10.2', 8443)


if __name__ == '__main__':
    unittest.main()
