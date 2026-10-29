import json
from pathlib import Path
import tempfile
import unittest

import ledger
import retained_actions


class RetainedActionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        for folder in ['tool/dify_spec', 'tool/design', 'app/test']:
            (self.repo / folder).mkdir(parents=True)
        self.key = 'web/shared-modal.spec.tsx :: SharedModal > removes a model'
        self.action = dict(
            id='model.remove', upstream_case=self.key, test_file='app/test/row_test.dart',
            test_name='removes a model from the row', difference='Retained outside the deferred modal.',
        )
        (self.repo / 'tool/dify_spec/cases.txt').write_text(self.key + '\n')
        (self.repo / 'tool/design/reference.json').write_text(json.dumps({'commit': 'pin'}))
        (self.repo / 'app/test/row_test.dart').write_text("testWidgets('removes a model from the row', (t) async {});\n")
        self.save()

    def save(self, pin='pin'):
        (self.repo / 'tool/dify_spec/retained_actions.json').write_text(json.dumps({
            'version': 1, 'upstream_commit': pin, 'actions': [self.action],
        }))

    def test_mapping_requires_a_real_local_test_and_pinned_upstream_case(self):
        self.assertEqual(retained_actions.load(self.repo, ledger.cases), [self.action])
        self.action['test_name'] = 'only a claimed name'
        self.save()
        with self.assertRaisesRegex(ValueError, 'Missing retained interaction test'):
            retained_actions.load(self.repo, ledger.cases)

    def test_component_exclusion_cannot_swallow_a_retained_action(self):
        (self.repo / 'tool/dify_spec/not_applicable.tsv').write_text(self.key + '\tDefer the entire modal\n')
        with self.assertRaisesRegex(ValueError, 'cannot be excluded'):
            retained_actions.load(self.repo, ledger.cases)

    def test_reference_change_requires_revisiting_the_mapping(self):
        self.save(pin='another-version')
        with self.assertRaisesRegex(ValueError, 'pinned upstream'):
            retained_actions.load(self.repo, ledger.cases)

    def test_only_a_passed_unskipped_interaction_from_the_right_file_is_evidence(self):
        events = [
            {'type': 'suite', 'suite': {'id': 1, 'path': str(self.repo / self.action['test_file'])}},
            {'type': 'testStart', 'test': {'id': 2, 'suiteID': 1, 'name': self.action['test_name']}},
            {'type': 'testDone', 'testID': 2, 'result': 'success', 'skipped': False},
            {'type': 'done', 'success': True},
        ]
        log = self.repo / 'results.jsonl'
        def write():
            log.write_text('\n'.join(json.dumps(e) for e in events))
        write()
        retained_actions.check_results([self.action], log)
        events[2]['skipped'] = True
        write()
        with self.assertRaisesRegex(ValueError, 'did not pass'):
            retained_actions.check_results([self.action], log)
        events[2]['skipped'] = False
        events[0]['suite']['path'] = '/unrelated/another_test.dart'
        write()
        with self.assertRaisesRegex(ValueError, 'did not pass'):
            retained_actions.check_results([self.action], log)


if __name__ == '__main__':
    unittest.main()
