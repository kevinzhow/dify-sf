"""Design-system check (ratchet) for the Flutter client: UI is built from app/lib/src/design/ first.

  python3 tool/design/check.py                  # same as --check
  python3 tool/design/check.py --check          # exit 1 on a new violation, a raised count, a stale or bad row
  python3 tool/design/check.py --update         # tighten tool/design/allowlist.tsv: lower counts, drop zero rows
  python3 tool/design/check.py --update --allow-increase --reason 'legit:<why>'
                                                # also raise counts / add rows (new rows get --reason;
                                                # `--reason todo` = todo:step<N> of the rule's migration step)
  python3 tool/design/check.py --top 15         # also list the files with the most hits

Scans app/lib/src/**/*.dart except *.g.dart. Comments and string literals are blanked before matching. Rules and the
allowlist format are described in tool/design/README.md. Pure stdlib.
"""
import argparse
import bisect
import os
import posixpath
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SRC_REL = 'app/lib/src'
ALLOWLIST_REL = 'tool/design/allowlist.tsv'
PACKAGE = 'dify_sf_app'  # app/pubspec.yaml name; `package:dify_sf_app/src/...` resolves to app/lib/src/...
DESIGN = 'design/'
DESIGN_IMPORT_OK = ('design/', 'i18n/')  # what design/ may import from app/lib/src

REASON_RE = re.compile(r'(third-party|dify-hardcoded|legit):\S.*|dev-shell|todo:step\d+')
# Migration step (ds-audit §5) that removes each rule's hits; `--reason todo` uses it.
TODO_STEP = {
    'color-literal': 4, 'box-shadow': 3, 'raw-text-style': 5, 'dialog-route': 3, 'material-widget': 3,
    'component-token': 3, 'dify-class': 2, 'design-import': 1,
}
# Files whose primitives move into design/ in step 1 (pure moves).
STEP1_FILES = {
    'workflow_editor/panel_fields/controls.dart', 'workflow_editor/panel_fields/form_controls.dart',
    'workflow_editor/panel_fields/selectors.dart', 'workflow_editor/panel_fields/dialog.dart',
    'workflow_editor/panel_fields/date_picker.dart', 'cards/card_kit.dart',
}

# --- rules -------------------------------------------------------------------------------------------------

GENERIC = r'(?:\s*<[\w<>?,\s]*>)?\s*\('  # optional type arguments, then the call's '('
COLOR_RE = re.compile(r'\bColor\(\s*0[xX]|\bColor\.from(?:ARGB|RGBO)\(|(?<![\w$.])Colors\.(?!transparent\b)\w+')
SHADOW_RE = re.compile(r'(?<![\w$])BoxShadow\(')
TEXT_STYLE_RE = re.compile(r'(?<![\w$.])TextStyle\(')
TEXT_STYLE_ARGS_RE = re.compile(r'\b(?:fontSize|fontWeight|height|letterSpacing)\s*:')
DIALOG_RE = re.compile(
    r'(?<![\w$.])(?:showDialog|showGeneralDialog|showModalBottomSheet|showMenu|showCupertinoDialog)' + GENERIC)
MATERIAL_RE = re.compile(
    r'(?<![\w$])(?:[a-zA-Z_]\w*\.)?(?:Material|MaterialApp|MaterialPageRoute|CupertinoPageRoute|Scaffold|AppBar'
    r'|TextField|TextFormField|InputDecorator|InputDecoration|SelectableText|SelectionArea|Scrollbar|ScrollbarTheme'
    r'|ReorderableListView|MenuAnchor|MenuItemButton|SubmenuButton|AlertDialog|SimpleDialog|Dialog|Switch(?:ListTile)?'
    r'|Checkbox(?:ListTile)?|Radio(?:ListTile)?|Slider|DropdownButton\w*|TabBar|Tooltip|PopupMenuButton|PopupMenuItem'
    r'|ElevatedButton|TextButton|OutlinedButton|FilledButton|IconButton|CircularProgressIndicator'
    r'|LinearProgressIndicator|SnackBar|Chip|ListTile|Card|InkWell|Badge|AdaptiveTextSelectionToolbar)'
    r'(?:\.[a-zA-Z_]\w*)?' + GENERIC)

COMPONENT_TOKEN_RE = re.compile(
    r'\bDifyColors\.components(?:Checkbox|Radio|Toggle|Slider|SegmentedControl|BadgeStatusLight|Input)\w*')
DIFY_CLASS_RE = re.compile(r'\b(?:class|mixin|enum)\s+(Dify\w+)')
DIFY_CLASS_OK = re.compile(
    r'Dify(?:WorkflowEditor|CodeEditor|PromptEditor\w*|Cards|NodeCard|FlowNode|FlowEdge|Markdown|DocumentTitle\w*|I18n|Var)')
IMPORT_RE = re.compile(r'''^[ \t]*(?:import|export)\s+(['"])([^'"\n]+)\1''', re.M)

RULES = ['color-literal', 'box-shadow', 'raw-text-style', 'dialog-route', 'material-widget', 'component-token',
         'dify-class', 'design-import', 'focus-ring', 'text-line']


def _close_paren(text, i):
    """Index of the ')' closing the '(' at text[i - 1]; also returns the arguments at depth 1 only."""
    depth, top, start = 1, [], i
    n = len(text)
    while i < n:
        c = text[i]
        if c in '([{':
            if depth == 1:
                top.append(text[start:i])
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                top.append(text[start:i])
                return i, ''.join(top)
            if depth == 1:
                start = i + 1
        i += 1
    top.append(text[start:])
    return n, ''.join(top)


def scan_file(rel, src):
    """[(rule, offset)] for one file. `rel` is relative to app/lib/src."""
    code = strip(src)
    hits = []
    if rel != 'design/widgets/text_line.dart':
        hits += [('text-line', m.start()) for m in re.finditer(
            r'(?<![\w$])(?:[a-zA-Z_]\w*\.)?Text(?:\.rich)?\s*\(', code)]
    for m in re.finditer(r'(?<![\w$.])BoxDecoration\(', code):
        end, _ = _close_paren(code, m.end())
        if re.search(r'difyFocusRing(?:Shadow)?\(', code[m.end():end]):
            hits.append(('focus-ring', m.start()))
    if rel.startswith(DESIGN):
        for m in IMPORT_RE.finditer(src):
            if not code[m.start():m.end()].strip():
                continue  # commented out
            target = _resolve(rel, m.group(2))
            if target is not None and not target.startswith(DESIGN_IMPORT_OK):
                hits.append(('design-import', m.start()))
        return hits
    for rule, rx in (('color-literal', COLOR_RE), ('box-shadow', SHADOW_RE), ('dialog-route', DIALOG_RE),
                     ('material-widget', MATERIAL_RE), ('component-token', COMPONENT_TOKEN_RE)):
        hits += [(rule, m.start()) for m in rx.finditer(code)]
    for m in TEXT_STYLE_RE.finditer(code):
        _, args = _close_paren(code, m.end())
        if TEXT_STYLE_ARGS_RE.search(args):
            hits.append(('raw-text-style', m.start()))
    for m in DIFY_CLASS_RE.finditer(code):
        if not DIFY_CLASS_OK.fullmatch(m.group(1)):
            hits.append(('dify-class', m.start()))
    return hits


def _resolve(rel, uri):
    """Path relative to app/lib/src of an import inside it, or None when it points elsewhere (dart:, packages)."""
    prefix = f'package:{PACKAGE}/'
    if uri.startswith(prefix):
        path = 'lib/' + uri[len(prefix):]
        return path[len('lib/src/'):] if path.startswith('lib/src/') else '../' + path
    if ':' in uri:
        return None
    path = posixpath.normpath(posixpath.join(posixpath.dirname(rel), uri))
    return path


# --- comment / string stripping ----------------------------------------------------------------------------

_CODE = re.compile(r'''//|/\*|(?<![\w$])r?(?:\'\'\'|"""|'|")''')
_CODE_BRACES = re.compile(r'''//|/\*|(?<![\w$])r?(?:\'\'\'|"""|'|")|[{}]''')
_BLOCK = re.compile(r'/\*|\*/')
_STRING_END = {}
for _q in ("'''", '"""', "'", '"'):
    _nl = '' if len(_q) == 3 else r'|\n'
    _STRING_END[_q] = re.compile(r'\\.|\$\{|' + re.escape(_q) + _nl, re.S)
    _STRING_END['r' + _q] = re.compile(re.escape(_q) + _nl)


def strip(src):
    """`src` with comments and string literals (with their interpolations) replaced by spaces; newlines kept."""
    ranges = []
    _skip_code(src, 0, False, ranges)
    if not ranges:
        return src
    out, pos = [], 0
    for s, e in ranges:
        if s < pos:
            continue
        out.append(src[pos:s])
        piece = src[s:e]
        out.append(' ' * len(piece) if '\n' not in piece else re.sub(r'[^\n]', ' ', piece))
        pos = e
    out.append(src[pos:])
    return ''.join(out)


def _skip_code(src, i, interpolation, ranges):
    """Scan code from i. In an interpolation, return the index after its closing '}'; else scan to the end."""
    rx, depth, n = (_CODE_BRACES if interpolation else _CODE), 0, len(src)
    while True:
        m = rx.search(src, i)
        if not m:
            return n
        t, s = m.group(), m.start()
        if t == '{':
            depth += 1
            i = m.end()
        elif t == '}':
            if depth == 0:
                return m.end()
            depth -= 1
            i = m.end()
        elif t == '//':
            e = src.find('\n', s)
            i = n if e < 0 else e
            ranges.append((s, i))
        elif t == '/*':
            i = _skip_block(src, m.end())
            ranges.append((s, i))
        else:
            i = _skip_string(src, m.end(), t, ranges)
            ranges.append((s, i))


def _skip_block(src, i):
    depth = 1
    while depth:
        m = _BLOCK.search(src, i)
        if not m:
            return len(src)
        depth += 1 if m.group() == '/*' else -1
        i = m.end()
    return i


def _skip_string(src, i, quote, ranges):
    rx = _STRING_END[quote]
    while True:
        m = rx.search(src, i)
        if not m:
            return len(src)
        t = m.group()
        if t == '${':
            i = _skip_code(src, m.end(), True, ranges)
        elif t.startswith('\\'):
            i = m.end()
        elif t == '\n':
            return m.start()  # unterminated single-line string: stop at the line end
        else:
            return m.end()


# --- tree, allowlist ---------------------------------------------------------------------------------------

def scan_tree(src_root):
    """{(rule, rel): [offset lines]} and {rel: source lines} for files with hits."""
    hits, lines = defaultdict(list), {}
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith('.dart') or name.endswith('.g.dart'):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, src_root).replace(os.sep, '/')
            with open(path, encoding='utf-8') as f:
                src = f.read()
            found = scan_file(rel, src)
            if not found:
                continue
            starts = [0] + [m.end() for m in re.finditer('\n', src)]
            for rule, off in found:
                hits[(rule, rel)].append(bisect.bisect_right(starts, off))
            lines[rel] = src.splitlines()
    return hits, lines


def read_allowlist(path):
    """({(rule, rel): (max, reason)}, [errors])."""
    rows, errors, keys = {}, [], []
    if not path.exists():
        return rows, errors
    for no, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        where = f'{ALLOWLIST_REL}:{no}'
        parts = line.split('\t')
        if len(parts) != 4:
            errors.append(f'{where}: expected 4 tab-separated fields (rule, path, max_count, reason)')
            continue
        rule, rel, count, reason = parts
        if rule in ('material-widget', 'focus-ring', 'text-line'):
            errors.append(f'{where}: {rule} exceptions are prohibited; use design/ components')
        if rule not in RULES:
            errors.append(f'{where}: unknown rule {rule!r}')
        if not count.isdigit() or int(count) == 0:
            errors.append(f'{where}: max_count must be a positive integer')
            continue
        if not REASON_RE.fullmatch(reason):
            errors.append(f'{where}: reason {reason!r} must be third-party:<lib>, dev-shell, '
                          f'dify-hardcoded:<dify path>, legit:<why> or todo:step<N>')
        if (rule, rel) in rows:
            errors.append(f'{where}: duplicate row for {rule} {rel}')
        keys.append((rule, rel))
        rows[(rule, rel)] = (int(count), reason)
    if keys != sorted(keys):
        errors.append(f'{ALLOWLIST_REL}: rows are not sorted by (rule, path): run --update')
    return rows, errors


def write_allowlist(path, rows):
    out = ['# rule\tpath (under app/lib/src)\tmax_count\treason    -- see tool/design/README.md']
    out += [f'{r}\t{p}\t{c}\t{why}' for (r, p), (c, why) in sorted(rows.items())]
    path.write_text('\n'.join(out) + '\n', encoding='utf-8')


def default_reason(rule, rel):
    if rel.startswith('editor/') or rel == 'home_page.dart':
        return 'dev-shell'
    if rule in ('component-token', 'dify-class') and rel in STEP1_FILES:
        return 'todo:step1'
    return f'todo:step{TODO_STEP[rule]}'


# --- main --------------------------------------------------------------------------------------------------

def snippet(lines, rel, no):
    text = lines[rel][no - 1].strip() if no - 1 < len(lines[rel]) else ''
    return text if len(text) <= 110 else text[:107] + '...'


def run(argv=None, root=REPO, out=sys.stdout, err=sys.stderr):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--check', action='store_true', help='fail on violations (the default)')
    ap.add_argument('--update', action='store_true', help='rewrite the allowlist: only lowers counts / drops rows')
    ap.add_argument('--allow-increase', action='store_true', help='with --update: also raise counts and add rows')
    ap.add_argument('--reason', help='reason for rows added by --allow-increase (`todo` = todo:step<N> per rule)')
    ap.add_argument('--top', type=int, default=0, metavar='N', help='also list the N files with the most hits')
    args = ap.parse_args(argv)
    if args.allow_increase and not (args.update and args.reason):
        ap.error('--allow-increase needs --update and --reason')
    if args.reason and args.reason != 'todo' and not REASON_RE.fullmatch(args.reason):
        ap.error(f'bad --reason {args.reason!r}')

    root = Path(root)
    allow_path = root / ALLOWLIST_REL
    hits, lines = scan_tree(root / SRC_REL)
    rows, errors = read_allowlist(allow_path)
    counts = {k: len(v) for k, v in hits.items()}

    if args.update:
        new_rows, log = {}, []
        for key in sorted(set(rows) | set(counts)):
            have, row = counts.get(key, 0), rows.get(key)
            if key[0] in ('material-widget', 'focus-ring', 'text-line') and have:
                continue  # No --allow-increase waiver for direct Material controls.
            if row is None:
                if args.allow_increase and have:
                    why = default_reason(*key) if args.reason == 'todo' else args.reason
                    new_rows[key] = (have, why)
                    log.append(f'added   {key[0]}\t{key[1]}\t{have}\t{why}')
                continue
            limit, why = row
            if have == 0:
                log.append(f'dropped {key[0]}\t{key[1]}\t(was {limit})')
            elif have < limit:
                new_rows[key] = (have, why)
                log.append(f'lowered {key[0]}\t{key[1]}\t{limit} -> {have}')
            elif have > limit and args.allow_increase:
                new_rows[key] = (have, why)
                log.append(f'raised  {key[0]}\t{key[1]}\t{limit} -> {have}')
            else:
                new_rows[key] = row
        write_allowlist(allow_path, new_rows)
        print('\n'.join(log) or 'allowlist already tight', file=out)
        print(f'wrote {ALLOWLIST_REL} ({len(new_rows)} rows)', file=out)
        rows, errors = read_allowlist(allow_path)

    # violations
    new, stale = [], []
    for key in sorted(set(rows) | set(counts)):
        have, row = counts.get(key, 0), rows.get(key)
        limit = row[0] if row else 0
        if have > limit:
            rule, rel = key
            head = f'{rel}: {rule} {have} > allowed {limit}' if row else f'{rel}: {rule} {have} (not allowlisted)'
            new.append(head)
            new += [f'  {rel}:{no} {rule}: {snippet(lines, rel, no)}' for no in hits[key]]
        elif have < limit:
            stale.append(f'{key[1]}: {key[0]} {have} < allowed {limit} (stale: run --update)')

    # summary
    per_rule, files = Counter(), defaultdict(set)
    for (rule, rel), n in counts.items():
        per_rule[rule] += n
        files[rule].add(rel)
    over = Counter(k[0] for k in counts if counts[k] > rows.get(k, (0,))[0])
    for rule in RULES:
        flag = f'  {over[rule]} file(s) over' if over[rule] else ''
        print(f'{rule:16} {per_rule[rule]:5} hits in {len(files[rule]):3} files{flag}', file=out)
    if args.top:
        per_file = Counter()
        for (_, rel), n in counts.items():
            per_file[rel] += n
        print(f'top {args.top} files:', file=out)
        for rel, n in per_file.most_common(args.top):
            parts = ', '.join(f'{r} {counts[(r, rel)]}' for r in RULES if (r, rel) in counts)
            print(f'  {n:4} {rel}  ({parts})', file=out)

    problems = errors + new + stale
    if problems:
        print('\n'.join(problems), file=err)
        print(f'design check FAILED: {sum(1 for k in counts if counts[k] > rows.get(k, (0,))[0])} over the '
              f'allowlist, {len(stale)} stale, {len(errors)} allowlist error(s). Use design/ primitives, or see '
              f'tool/design/README.md for exceptions.', file=err)
        return 1
    print(f'design check OK ({sum(counts.values())} allowlisted hits in {len(rows)} rows)', file=out)
    return 0


if __name__ == '__main__':
    sys.exit(run())
