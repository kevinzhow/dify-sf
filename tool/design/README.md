# Design-system check

UI is built from `app/lib/src/design/` first. `check.py` scans `app/lib/src/**/*.dart` (not `*.g.dart`), with
comments and strings blanked, and compares the hits per (rule, file) with `allowlist.tsv`. The allowlist is a
ratchet: counts may only go down. Direct Material controls in business code are prohibited, including the former dev shell; `material-widget` has no exceptions. Framework text entry, selection, page hosts and desktop routes are owned by `design/`, with Dify styling and explicit layout defaults.

```sh
python3 tool/design/check.py              # = --check: exit 1 on a new hit, a raised count, a stale or bad row
python3 tool/design/check.py --update     # after removing hits: lower counts, drop rows at zero (never raises)
python3 tool/design/check.py --top 15     # also list the files with the most hits
python3 -m unittest tool/design/test_check.py
```

## Rules

Outside `design/`:

| rule | flags | use instead |
|---|---|---|
| `color-literal` | `Color(0x…)`, `Color.fromARGB/fromRGBO(`, `Colors.*` (not `Colors.transparent`) | `DifyColors.*`, named constants in design/ |
| `box-shadow` | `BoxShadow(` | `DifyShadows.*`, design helpers (focus ring, status dot) |
| `raw-text-style` | `TextStyle(` that sets `fontSize`, `fontWeight`, `height` or `letterSpacing` (colour-only is fine) | `difyTextStyle(DifyType.…, color)` |
| `dialog-route` | calls to `showDialog`, `showGeneralDialog`, `showModalBottomSheet`, `showMenu`, `showCupertinoDialog` | `showDifyDialog` and the design dialogs |
| `material-widget` | `AlertDialog`, `Dialog`, `Switch`, `Checkbox`, `Radio`, `Slider`, `DropdownButton*`, `TabBar`, `Tooltip`, `PopupMenuButton`, Material buttons, progress indicators, `SnackBar`, `Chip`, `InputDecoration` | the `Dify*` widget |
| `component-token` | `DifyColors.components(Checkbox\|Radio\|Toggle\|Slider\|SegmentedControl\|BadgeStatusLight\|Input)*` | the widget that owns the token |
| `dify-class` | `class/mixin/enum Dify…` declared outside design/ (feature-level exceptions: `DifyWorkflowEditor`, `DifyCodeEditor`, `DifyPromptEditor*`, `DifyCards`, `DifyNodeCard`, `DifyFlowNode`, `DifyFlowEdge`, `DifyMarkdown`, `DifyDocumentTitle*`) | move it into design/ |

Inside `design/`: `design-import` flags an import that resolves outside `design/` and `i18n/` (packages are fine).

## Adding an exception

Prefer fixing the code. If the hit is right (third-party colours, a literal Dify itself hard-codes), run

```sh
python3 tool/design/check.py --update --allow-increase --reason 'legit:<why>'
```

New rows get `--reason`; raised rows keep their reason. Review the diff of `allowlist.tsv` and make the reason
precise before merging. Each row is `rule<TAB>path under app/lib/src<TAB>max_count<TAB>reason`, sorted.

Reasons (required, one of):

- `third-party:<lib>`: values copied from a library or the browser (Monaco, reactflow, github-markdown-css).
- `dev-shell`: development-only launch/collaboration utilities (`home_page.dart`, `editor/`); never an exception to the direct Material-control prohibition.
- `dify-hardcoded:<dify path>`: Dify hard-codes the same literal; cite the file under `dify-src/`.
- `legit:<why>`: allowed by design (for example `legit:transparent`).
- `todo:step<N>`: baseline debt, removed by step N of the migration plan (1 moves into design/, 2 extracts private
  components, 3 new primitives, 4 colours, 5 typography). `--reason todo` picks the step per rule.

The goal is an allowlist with only `third-party`, `dev-shell` and `legit` rows (`dify-hardcoded` literals move into
design/ as named constants that cite the Dify file).

Focus rings use `DifyFocusDecoration` with `difyFocusRing` / `difyFocusRingShadow`. They are outside-only strokes, including during animations. A plain `BoxDecoration` with a solid focus shadow fills the area underneath a translucent control and changes its background; the check rejects that combination.
