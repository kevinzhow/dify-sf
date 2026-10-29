"""Feature parity list of dify-sf's Flutter port of Dify 1.17.1.

  python3 tool/features/gen.py                  # write docs/features.md and the README blocks
  python3 tool/features/gen.py --check          # fail (exit 1) on an invalid list or stale output
  python3 tool/features/gen.py --check --dify ~/path/to/dify-src
                                                # also: every `dify` path exists, cases.txt matches the ledger
  python3 tool/features/gen.py --readme ../dify-sf/README.md
                                                # also update / check another README's block

The source of truth is tool/features/features.yaml (format described at its top). The generated outputs are
docs/features.md and, in every README given, the block between `<!-- features:begin -->` and
`<!-- features:end -->`: this repository's README.md always; the server repository's README.md when it is passed
with --readme or found next to this checkout (../dify-sf/README.md, if it has the markers).

The check (also run before writing) verifies: required fields, known areas and statuses, unique ids prefixed by
their area, a reason for every status other than `ported`, evidence that resolves (spec:<dir or spec file> against
tool/dify_spec/cases.txt, visual:<id> against tool/visual/cases.json, else a path in this repository), existing
`ours` paths, and that every Dify spec directory the ledger knows (cases.txt) is named by some feature's evidence.
Needs PyYAML.
"""
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit('tool/features/gen.py needs PyYAML (python3 -m pip install pyyaml, or apt install python3-yaml)')

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'tool/features/features.yaml'
DOC = REPO / 'docs/features.md'
CASES = REPO / 'tool/dify_spec/cases.txt'
VISUAL = REPO / 'tool/visual/cases.json'
README = REPO / 'README.md'
SERVER_README = REPO.parent / 'dify-sf/README.md'
# Unified main publishes both client and server; external READMEs link to this list.
PUBLIC_DOC = 'https://github.com/kevinzhow/dify-sf/blob/main/docs/features.md'

STATUSES = ['ported', 'partial', 'not_ported', 'not_applicable', 'dify_sf_only']
LABELS = {'ported': 'ported', 'partial': 'partial', 'not_ported': 'not ported', 'not_applicable': 'n/a',
          'dify_sf_only': 'dify-sf only'}
REQUIRED = ['id', 'area', 'title', 'dify', 'status', 'evidence', 'ours']
FIELDS = set(REQUIRED) | {'reason', 'deviation'}
BEGIN, END = '<!-- features:begin -->', '<!-- features:end -->'


def spec_dir(path):
    """The spec directory of a spec file or directory: its parent with a trailing __tests__ dropped."""
    p = Path(path)
    d = p.parent if p.suffix in ('.ts', '.tsx') else p
    return (d.parent if d.name == '__tests__' else d).as_posix()


def load_cases():
    files = set()
    for line in CASES.read_text().splitlines():
        if ' :: ' in line:
            files.add(line.split(' :: ', 1)[0])
    return files


def validate(data, dify_root=None):
    errors = []
    # Component-level deferrals must not silently exclude a retained action.
    sys.path.insert(0, str(REPO / 'tool/dify_spec'))
    import ledger
    try:
        ledger.retained_actions.load(REPO, ledger.cases)
    except (ValueError, KeyError, OSError) as error:
        errors.append(str(error))
    areas = data.get('areas') or []
    area_ids = [a.get('id') for a in areas]
    if len(set(area_ids)) != len(area_ids):
        errors.append('duplicate area ids')
    features = data.get('features') or []
    spec_files = load_cases()
    spec_dirs = {spec_dir(f) for f in spec_files}
    visual_ids = {c.get('id') for c in json.loads(VISUAL.read_text())}
    covered, seen = set(), set()
    for i, f in enumerate(features):
        where = f"feature #{i + 1} ({f.get('id', '?')})"
        if not isinstance(f, dict):
            errors.append(f'{where}: not a mapping')
            continue
        for k in REQUIRED:
            if k not in f or f[k] is None or (k in ('id', 'area', 'title', 'status') and not str(f[k]).strip()):
                errors.append(f'{where}: missing {k}')
        for k in f:
            if k not in FIELDS:
                errors.append(f'{where}: unknown field {k}')
        for k in ('dify', 'evidence', 'ours'):
            if k in f and not isinstance(f[k], list):
                errors.append(f'{where}: {k} must be a list')
        fid = f.get('id')
        if fid in seen:
            errors.append(f'{where}: duplicate id')
        seen.add(fid)
        if f.get('area') not in area_ids:
            errors.append(f"{where}: unknown area {f.get('area')!r}")
        elif fid and not str(fid).startswith(f"{f['area']}."):
            errors.append(f"{where}: id must start with '{f['area']}.'")
        status = f.get('status')
        if status not in STATUSES:
            errors.append(f'{where}: unknown status {status!r}')
        if status != 'ported' and not str(f.get('reason') or '').strip():
            errors.append(f'{where}: status {status} needs a reason')
        if status == 'ported' and f.get('reason'):
            errors.append(f'{where}: a ported feature has no reason (use deviation)')
        for e in f.get('evidence') or []:
            e = str(e)
            if e.startswith('spec:'):
                path = e[5:]
                if path in spec_files or path in spec_dirs:
                    covered.add(spec_dir(path))
                else:
                    errors.append(f'{where}: evidence {e} is not a spec file or directory in tool/dify_spec/cases.txt')
            elif e.startswith('visual:'):
                if e[7:] not in visual_ids:
                    errors.append(f'{where}: evidence {e} is not a case id in tool/visual/cases.json')
            elif not (REPO / e).exists():
                errors.append(f'{where}: evidence path {e} does not exist')
        for o in f.get('ours') or []:
            if not (REPO / str(o)).exists():
                errors.append(f'{where}: ours path {o} does not exist')
        if dify_root:
            for d in f.get('dify') or []:
                if not (dify_root / str(d)).exists():
                    errors.append(f'{where}: dify path {d} does not exist in {dify_root}')
    for d in sorted(spec_dirs - covered):
        errors.append(f'spec directory {d} is not named by any feature evidence')
    if dify_root:
        sys.path.insert(0, str(REPO / 'tool/dify_spec'))
        import ledger
        current = ''.join(f'{s} :: {c}\n' for s, c in ledger.dify_cases(dify_root))
        if current != CASES.read_text():
            errors.append('tool/dify_spec/cases.txt is stale: run python3 tool/dify_spec/ledger.py <dify> --write')
    return errors


def counts(features):
    c = {s: 0 for s in STATUSES}
    for f in features:
        c[f['status']] += 1
    return c


def cell(text):
    return ' '.join(str(text).split()).replace('|', '\\|')


def evidence_text(items):
    out = []
    for e in items:
        e = str(e)
        if e.startswith('spec:'):
            out.append('spec `' + e[5:].replace('web/app/components/', '').replace('/__tests__/', '/') + '`')
        elif e.startswith('visual:'):
            out.append('visual `' + e[7:] + '`')
        else:
            out.append('`' + e + '`')
    return ', '.join(out)


def summary_rows(data):
    by_area = {a['id']: [] for a in data['areas']}
    for f in data['features']:
        by_area[f['area']].append(f)
    head = '| Area | ' + ' | '.join(LABELS[s] for s in STATUSES) + ' | total |'
    rows = [head, '|' + '---|' * (len(STATUSES) + 2)]
    for a in data['areas']:
        fs = by_area[a['id']]
        c = counts(fs)
        rows.append(f"| [{cell(a['title'])}](#{a['id']}) | " + ' | '.join(str(c[s] or '') for s in STATUSES)
                    + f' | {len(fs)} |')
    c = counts(data['features'])
    rows.append('| **Total** | ' + ' | '.join(f'**{c[s]}**' for s in STATUSES) + f" | **{len(data['features'])}** |")
    return rows, by_area


def render_doc(data):
    rows, by_area = summary_rows(data)
    lines = [
        '# Feature parity with Dify 1.17.1',
        '',
        '<!-- Generated by tool/features/gen.py from tool/features/features.yaml. Do not edit by hand. -->',
        '',
        "Which features of Dify 1.17.1's workflow editor (and the pages around it) dify-sf's Flutter app has, which it",
        'does not, and why. One row per feature or distinct behaviour. Statuses:',
        '',
        '- **ported**: works as in Dify (a *deviation* notes where it is intentionally different, and why);',
        '- **partial**: part of it is ported, the reason says what is missing;',
        '- **not ported**: not there, the reason says why (a decision, a missing backend service, not done yet);',
        '- **n/a**: does not apply to dify-sf (its own design replaces it, or it is a Dify Cloud / enterprise feature);',
        "- **dify-sf only**: dify-sf's own, Dify has no counterpart.",
        '',
        "Evidence: `spec` names Dify's own unit tests ported to Dart (`app/test/dify_spec/`, counted by",
        '`tool/dify_spec/ledger.py`), `visual` a pixel comparison case against a real Dify (`tool/visual/cases.json`).',
        '',
        '## Summary',
        '',
        *rows,
    ]
    for a in data['areas']:
        lines += ['', f"<a id=\"{a['id']}\"></a>", '', f"## {a['title']}", '',
                  '| Feature | Status | Reason / deviation | Evidence |', '|---|---|---|---|']
        for f in by_area[a['id']]:
            note = f.get('reason') or ''
            if f.get('deviation'):
                note = (note + ' ' if note else '') + 'Deviation: ' + f['deviation']
            lines.append(f"| {cell(f['title'])} | {LABELS[f['status']]} | {cell(note)} | "
                         f"{cell(evidence_text(f.get('evidence') or []))} |")
    return '\n'.join(lines) + '\n'


def render_block(data, link, inside=True):
    c = counts(data['features'])
    total = len(data['features'])
    source = '`tool/features/features.yaml`' + ('' if inside else ' on the client branch')
    lines = [BEGIN, '## Feature parity with Dify 1.17.1', '',
             f"{total} features of Dify 1.17.1's workflow editor and the pages around it, tracked one by one in "
             f'[docs/features.md]({link}) (generated from {source}):', '',
             '| Status | Features |', '|---|---|']
    for s in STATUSES:
        lines.append(f'| {LABELS[s]} | {c[s]} |')
    lines += ['', f'Per area, with the reason for everything not ported: [docs/features.md]({link}).', END]
    return '\n'.join(lines)


def with_block(text, block):
    if BEGIN in text and END in text:
        start, end = text.index(BEGIN), text.index(END) + len(END)
        return text[:start] + block + text[end:]
    return None


def readmes(extra):
    paths = [README] + [Path(p).resolve() for p in extra]
    if SERVER_README.exists() and BEGIN in SERVER_README.read_text() and SERVER_README.resolve() not in paths:
        paths.append(SERVER_README.resolve())
    return paths


def main(argv):
    check = '--check' in argv
    dify_root = Path(argv[argv.index('--dify') + 1]).expanduser() if '--dify' in argv else None
    extra = [argv[i + 1] for i, a in enumerate(argv) if a == '--readme']
    data = yaml.safe_load(SOURCE.read_text())
    errors = validate(data, dify_root)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        print(f'{len(errors)} problem(s) in {SOURCE.relative_to(REPO)}', file=sys.stderr)
        return 1
    outputs = {DOC: render_doc(data)}
    for path in readmes(extra):
        inside = path.is_relative_to(REPO)
        block = render_block(data, 'docs/features.md' if inside else PUBLIC_DOC, inside)
        text = path.read_text() if path.exists() else ''
        new = with_block(text, block)
        if new is None:
            print(f'{path}: no {BEGIN} ... {END} block', file=sys.stderr)
            return 1
        outputs[path] = new
    stale = [p for p, text in outputs.items() if not p.exists() or p.read_text() != text]
    if check:
        for p in stale:
            print(f'{p} is stale: run python3 tool/features/gen.py', file=sys.stderr)
        if stale:
            return 1
        c = counts(data['features'])
        print(f"{len(data['features'])} features OK: " + ', '.join(f'{c[s]} {LABELS[s]}' for s in STATUSES))
        return 0
    for p in stale:
        p.write_text(outputs[p])
        print(f'wrote {p}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
