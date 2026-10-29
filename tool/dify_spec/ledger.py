"""Ledger of Dify's own frontend unit tests (vitest) that the Flutter port must pass.

  python3 tool/dify_spec/ledger.py <dify source root> [--write]

Lists every test case in Dify's specs for the parts we port (workflow editor, model provider page and the integrations page that hosts it, base/form, dify-ui, sign-in / install / activate / reset-password pages, account dropdown, account page, account setting with its members and preferences pages, main nav workspace card, workflow-app run hooks, the chat's human input forms, the theme selector, the Studio app list with its create / import / duplicate / edit-info
dialogs and their primitives) as
`<spec path> :: <describe> > ... > <it>`, and checks which are ported: a ported case is a Dart test under
app/test/dify_spec/ whose full name (group names joined with ' > ' and the test name) equals the Dify case name, in a
file that names the spec in a `// dify-spec: <spec path>` line. Cases that cannot apply are listed with a reason in
tool/dify_spec/not_applicable.tsv (`<spec path> :: <case>\\t<reason>`). --write saves the full case list to
tool/dify_spec/cases.txt. The optional todo.tsv records remaining work for applicable cases whose old exclusions were retired.
"""
import re, sys
from pathlib import Path
import retained_actions

ROOTS = ['web/app/components/workflow', 'web/app/components/header/account-setting/model-provider-page',
         'packages/dify-ui/src', 'web/app/components/app/app-publisher',
         'web/app/components/workflow-app/components/workflow-header', 'web/app/components/base/prompt-editor',
         'web/app/components/base/features', 'web/app/signin', 'web/app/install', 'web/app/activate',
         'web/app/components/header/account-dropdown', 'web/app/components/header/account-setting/members-page',
         'web/app/components/header/account-setting/__tests__',
         'web/app/components/main-nav/components/__tests__/workspace-card.spec.tsx',
         'web/app/components/workflow-app/hooks/__tests__/use-workflow-run.spec.ts',
         'web/app/components/workflow-app/hooks/__tests__/use-workflow-run-callbacks.spec.ts',
         'web/app/components/workflow-app/hooks/__tests__/use-workflow-run-utils.spec.ts',
         'web/app/components/workflow-app/hooks/__tests__/use-workflow-start-run.spec.tsx',
         'web/app/components/base/chat/chat/answer/human-input-content',
         'web/app/components/base/chat/chat/answer/__tests__/human-input-form-list.spec.tsx',
         'web/app/components/base/form', 'web/app/components/integrations',
         'web/app/reset-password', 'web/app/forgot-password',
         'web/app/components/base/__tests__/theme-selector.spec.tsx',
         'web/app/components/apps', 'web/app/components/app/create-app-modal',
         'web/app/components/app/create-from-dsl-modal', 'web/app/components/app/duplicate-modal',
         'web/app/components/explore/create-app-modal', 'web/app/components/app/__tests__',
         'web/app/components/app/type-selector', 'web/app/components/base/search-input',
         'web/app/components/base/infinite-scroll-sentinel',
         # App detail pages: Access Point (with the overview's Web App modals), API keys, annotations.
         'web/app/components/app/access-point', 'web/app/components/api-key', 'web/app/components/app/overview',
         'web/app/components/base/qrcode', 'web/app/components/app/annotation',
         # App detail shell (sidebar, routing, guards), Overview charts and Logs.
         'web/app/components/app-sidebar/__tests__/app-detail-section.spec.tsx',
         'web/app/components/app-sidebar/__tests__/app-detail-top.spec.tsx',
         'web/app/components/app-sidebar/app-info', 'web/app/components/app-sidebar/nav-link',
         'web/app/components/detail-sidebar', 'web/app/(commonLayout)/app/(appDetailLayout)',
         'web/app/components/app/log', 'web/app/components/app/workflow-log', 'web/app/components/app/log-annotation',
         'web/utils/permission.spec.ts', 'web/utils/app-redirection.spec.ts',
         # Account page and Preferences (protocol 1.12).
         'web/app/account/(commonLayout)', 'web/app/components/header/account-setting/preference-page',
         'web/app/components/header/account-setting/collapse']
CALL = re.compile(r'''^(\s*)(describe|it|test)(?:\.(?:each\([^)]*\)|skip|only|concurrent|todo))*\(\s*(['"`])(.*?)\3''')


def cases(text):
    # A call whose name is on the next line (formatters wrap long names) is joined onto the call's line.
    text = re.sub(r'\b(describe|it|test|group|testWidgets)\(\s*\n\s*([\'"`])', r'\1(\2', text)
    # `it.each(table)('name', …)`: the table may span lines; the case is named like a plain `it('name')`.
    text = re.sub(r'\b(describe|it|test)\.each\s*(?:`[^`]*`|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))\s*\(\s*', r'\1(', text)
    stack, out = [], []
    for line in text.splitlines():
        m = CALL.match(line)
        if not m:
            continue
        indent, kind, name = len(m.group(1)), m.group(2), m.group(4)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        if kind == 'describe':
            stack.append((indent, name))
        else:
            out.append(' > '.join([n for _, n in stack] + [name]))
    return out


def dify_cases(root):
    for base in ROOTS:
        p = root / base
        for f in [p] if p.is_file() else sorted(p.rglob('*.spec.ts*')):
            if 'node_modules' in f.parts:
                continue
            rel = f.relative_to(root).as_posix()
            for c in cases(f.read_text(errors='replace')):
                yield rel, c


def ported(repo):
    done = set()
    for f in (repo / 'app/test/dify_spec').rglob('*_test.dart'):
        text = f.read_text()
        specs = re.findall(r'//\s*dify-spec:\s*(\S+)', text)
        names = cases(text.replace('group(', 'describe(').replace('testWidgets(', 'test(').replace('\\$', '$'))
        for s in specs:
            done.update((s, n) for n in names)
    for action in retained_actions.load(repo, cases):
        spec, case = action['upstream_case'].split(' :: ', 1)
        done.add((spec, case))
    return done


def main():
    root, repo = Path(sys.argv[1]), Path(__file__).resolve().parents[2]
    all_cases = list(dify_cases(root))
    done = ported(repo)
    na = {}
    tsv = repo / 'tool/dify_spec/not_applicable.tsv'
    if tsv.exists():
        for line in tsv.read_text().splitlines():
            if '\t' in line and not line.startswith('#'):
                key, reason = line.split('\t', 1)
                na[key] = reason
    # A new port must retire its old exclusion. Silently preferring the port hid stale reasons in the past.
    overlap = sorted(f'{spec} :: {case}' for spec, case in done if f'{spec} :: {case}' in na)
    if overlap:
        raise SystemExit('Ported cases still listed as not applicable:\n' + '\n'.join(overlap))
    todos = repo / 'tool/dify_spec/todo.tsv'
    if todos.exists():
        for line in todos.read_text().splitlines():
            if '\t' not in line or line.startswith('#'):
                continue
            key = line.split('\t', 1)[0]
            if key in na:
                raise SystemExit('Case cannot be both TODO and not applicable: ' + key)
    if '--write' in sys.argv:
        (repo / 'tool/dify_spec/cases.txt').write_text(''.join(f'{s} :: {c}\n' for s, c in all_cases))
    by_area = {}
    for s, c in all_cases:
        area = '/'.join(s.split('/')[:5])
        st = 'ported' if (s, c) in done else 'n/a' if f'{s} :: {c}' in na else 'todo'
        by_area.setdefault(area, {'ported': 0, 'n/a': 0, 'todo': 0})[st] += 1
    total = {k: sum(v[k] for v in by_area.values()) for k in ('ported', 'n/a', 'todo')}
    print(f'{len(all_cases)} Dify cases: {total["ported"]} ported, {total["n/a"]} not applicable, {total["todo"]} to do')
    for area, v in sorted(by_area.items(), key=lambda kv: -sum(kv[1].values())):
        print(f'  {area}: {v["ported"]} ported, {v["n/a"]} n/a, {v["todo"]} to do')
    if '--results' in sys.argv:
        result = sys.argv[sys.argv.index('--results') + 1]
        retained_actions.check_results(retained_actions.load(repo, cases), result)
        print('Retained interaction actions: passed in the supplied test run')
    else:
        print('Inventory only: test names are not execution evidence; supply --results <Flutter --machine log>.')


if __name__ == '__main__':
    main()
