import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

import raft_report


def png(path, width=1):
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, 1, 8, 6, 0, 0, 0)) +
                     chunk(b'IDAT', zlib.compress(b'\0' + b'\xff\0\0\xff' * width)) + chunk(b'IEND', b''))


class ReportContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.framework = self.root / 'framework'
        (self.framework / 'src').mkdir(parents=True)
        (self.framework / 'src/cli.mjs').write_text('// pinned test framework')
        png(self.root / 'a.png')
        png(self.root / 'b.png')
        self.receipt = {
            'name': 'owned fixture', 'runId': 'test-run',
            'framework': {'files': {'src/cli.mjs': raft_report.sha(self.framework / 'src/cli.mjs')}},
            'project': {'source': 'owned test'}, 'pairs': ['react__flutter-web'],
            'cases': [{'id': 'components.test', 'captureType': 'component-fixture', 'captures': {
                'react': {'image': str(self.root / 'a.png'), 'source': 'actual-reference'},
                'flutter-web': {'image': str(self.root / 'b.png'), 'source': 'actual-candidate',
                                'access_token': 'must-not-be-published', 'headers': {'Authorization': 'private'}},
            }}],
        }

    def run_report(self):
        receipt = self.root / 'receipt.json'
        receipt.write_text(json.dumps(self.receipt))
        def command(args, **kw):
            if 'site' in args:
                (self.root / 'site').mkdir()
        with patch('raft_report.subprocess.run', side_effect=command) as run:
            result = raft_report.generate(receipt, self.framework, self.root / 'out', self.root / 'site', Path('/opt/node'))
        return result, run

    def test_raw_images_and_safe_metadata_survive_without_normalization_or_auth(self):
        result, run = self.run_report()
        image = self.root / 'out/visual-testing-results/flutter-web/components.test.png'
        self.assertEqual(image.read_bytes(), (self.root / 'b.png').read_bytes())
        text = image.with_suffix('.metadata.json').read_text()
        self.assertNotIn('must-not-be-published', text)
        self.assertNotIn('Authorization', text)
        self.assertEqual(json.loads(text)['source'], 'actual-candidate')
        self.assertEqual(result['images'][0]['size'], [1, 1])
        self.assertEqual(len(run.call_args_list), 2)
        self.assertIn('--skip-analysis', run.call_args_list[-1].args[0])

    def test_upstream_mutation_is_rejected_before_commands(self):
        (self.framework / 'src/cli.mjs').write_text('// changed')
        with self.assertRaisesRegex(ValueError, 'pinned receipt'):
            self.run_report()
        self.assertFalse((self.root / 'out').exists())

    def test_unequal_images_are_rejected_instead_of_resized(self):
        png(self.root / 'b.png', width=2)
        with self.assertRaisesRegex(ValueError, 'Unequal original dimensions'):
            self.run_report()

    def test_failed_cases_remain_in_the_manifest_as_missing(self):
        self.receipt['cases'].append({'id': 'pages.failed', 'captureType': 'real-screen',
                                     'captures': {}, 'captureErrors': ['real route did not reach expected state']})
        self.run_report()
        manifest = json.loads((self.root / 'out/cases.json').read_text())
        self.assertEqual([c['id'] for c in manifest['cases']], ['components.test', 'pages.failed'])
        self.assertTrue(manifest['cases'][1]['captureErrors'])
        self.assertFalse((self.root / 'out/visual-testing-results/react/pages.failed.png').exists())

    def test_empty_capture_requires_a_failure_receipt(self):
        self.receipt['cases'][0]['captures'] = {}
        with self.assertRaisesRegex(ValueError, 'explicit captureErrors'):
            self.run_report()

    def test_previous_output_is_immutable(self):
        (self.root / 'out').mkdir()
        marker = self.root / 'out/previous-failure'
        marker.write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'fresh output'):
            self.run_report()
        self.assertEqual(marker.read_text(), 'preserve')


if __name__ == '__main__':
    unittest.main()
