"""Run with python3 -m unittest discover -s agent_service/test/deploy -p '*_test.py'."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

DEPLOY = Path(__file__).resolve().parents[2] / 'deploy'
FILTER = DEPLOY / 'codex-gateway-error-log.awk'
LAUNCHER = DEPLOY / 'codex-gateway-diagnostics.sh'


class GatewayDiagnosticsTest(unittest.TestCase):
    def classify(self, lines):
        result = subprocess.run(['awk', '-W', 'interactive', '-f', str(FILTER)], input=lines,
                                text=True, capture_output=True, check=True)
        self.assertEqual(result.stderr, '')
        return [json.loads(row) for row in result.stdout.splitlines()]

    def test_timeout_and_reset_keep_connection_and_errno(self):
        rows = self.classify('2026 [info] 1#1: *17 upstream timed out (110: secret) while proxying upgraded connection\n'
                             '2026 [error] 1#1: *18 recv() failed (104: secret) while reading upstream\n')
        self.assertEqual((rows[0]['connection'], rows[0]['reason'], rows[0]['direction']), ('17', 'timeout', 'upstream'))
        self.assertEqual((rows[1]['connection'], rows[1]['reason'], rows[1]['system_errno']), ('18', 'connection_reset', '104'))

    def test_arbitrary_urls_headers_and_close_text_cannot_reach_logs(self):
        rows = self.classify('2026 [info] 1#1: *7 client sent too long header line: Authorization: Bearer secret-header\n'
                             '2026 [error] 1#1: *8 arbitrary secret-message at https://secret-host/?token=secret-token\n')
        self.assertNotIn('secret', json.dumps(rows))
        self.assertEqual(rows[1]['reason'], 'unclassified')
        self.assertEqual(rows[1]['direction'], 'unknown')

    def test_tunnel_reset_does_not_invent_which_peer_sent_it(self):
        row = self.classify('2026 [info] 1#1: *7 recv() failed (104: private) while proxying upgraded connection\n')[0]
        self.assertEqual(row['reason'], 'connection_reset')
        self.assertEqual(row['direction'], 'unknown')

    def test_oversized_untrusted_fields_produce_bounded_output(self):
        row = self.classify('2026 [warn] 1#1: *' + '9' * 10000 + ' private-body\n')[0]
        self.assertEqual(row['connection'], '')
        self.assertLess(len(json.dumps(row)), 250)

    def test_launcher_streams_redacted_errors_and_preserves_exit_status(self):
        with tempfile.TemporaryDirectory(prefix='codex-gateway-test-') as directory:
            root = Path(directory)
            fake = root / 'nginx'
            fake.write_text('#!/bin/sh\nprintf \'{"event":"fixture_access"}\\n\'\n'
                            'echo \'2026 [info] 1#1: *9 upstream timed out (110: secret-header) while proxying upgraded connection\' >&2\nexit 7\n')
            fake.chmod(0o755)
            config = root / 'nginx.conf'
            config.write_text('error_log /dev/stderr warn;\n')
            env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], TMPDIR=str(root))
            result = subprocess.run(['sh', str(LAUNCHER), str(config)], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 7)
            self.assertEqual(json.loads(result.stdout)['event'], 'fixture_access')
            self.assertEqual(json.loads(result.stderr)['reason'], 'timeout')
            self.assertNotIn('secret-header', result.stderr)
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['nginx', 'nginx.conf'])

    def test_launcher_rejects_an_unrecognized_logging_config(self):
        with tempfile.TemporaryDirectory(prefix='codex-gateway-test-') as directory:
            config = Path(directory) / 'nginx.conf'
            config.write_text('error_log /dev/stderr debug;\n')
            result = subprocess.run(['sh', str(LAUNCHER), str(config)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 64)
            self.assertNotIn('debug;', result.stderr)


if __name__ == '__main__':
    unittest.main()
