"""Retained actions inside otherwise deferred upstream components.

Mappings are explicit behavioral adaptations, not claims of pixel equivalence.
Validate them during inventory checks; use --results on a Flutter --machine log
to require the mapped interaction tests to have actually passed.
"""
import json
from pathlib import Path


def load(repo, test_cases):
    data = json.loads((repo / 'tool/dify_spec/retained_actions.json').read_text())
    pin = json.loads((repo / 'tool/design/reference.json').read_text())['commit']
    if data.get('version') != 1 or data.get('upstream_commit') != pin:
        raise ValueError('Retained actions must be reviewed against the pinned upstream commit')
    upstream = set((repo / 'tool/dify_spec/cases.txt').read_text().splitlines())
    excluded = set()
    for filename in ['not_applicable.tsv', 'todo.tsv']:
        p = repo / 'tool/dify_spec' / filename
        if p.exists():
            excluded.update(line.split('\t', 1)[0] for line in p.read_text().splitlines() if '\t' in line)
    seen = set()
    for action in data['actions']:
        key = action['upstream_case']
        if action['id'] in seen:
            raise ValueError('Duplicate retained action: ' + action['id'])
        seen.add(action['id'])
        if key not in upstream:
            raise ValueError('Unknown upstream action: ' + key)
        if key in excluded:
            raise ValueError('Retained action cannot be excluded or TODO: ' + key)
        p = (repo / action['test_file']).resolve()
        p.relative_to(repo.resolve())
        if not p.is_file() or action['test_name'] not in test_cases(
            p.read_text().replace('group(', 'describe(').replace('testWidgets(', 'test(')
        ):
            raise ValueError('Missing retained interaction test: ' + action['id'])
        if not action.get('difference', '').strip():
            raise ValueError('Explain the retained action adaptation: ' + action['id'])
    return data['actions']


def check_results(actions, path):
    suites, tests, passed = {}, {}, set()
    completed = False
    for line in Path(path).read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get('type')
        if kind == 'suite':
            suites[event['suite']['id']] = event['suite'].get('path', '')
        elif kind == 'testStart':
            tests[event['test']['id']] = event['test']
        elif kind == 'testDone' and event.get('result') == 'success' and not event.get('skipped', False):
            test = tests[event['testID']]
            source = test.get('root_url') or suites.get(test.get('suiteID'), '') or test.get('url', '')
            passed.add((source, test['name']))
        elif kind == 'done':
            completed = event.get('success') is True
    if not completed:
        raise ValueError('Interaction test run is incomplete or failed')
    for action in actions:
        name = action['test_name'].replace(' > ', ' ')
        if not any(source.endswith('/' + action['test_file']) and got == name for source, got in passed):
            raise ValueError('Retained action did not pass (missing, skipped or failed): ' + action['id'])
