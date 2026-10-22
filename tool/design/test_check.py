"""Tests for tool/design/check.py:  python3 -m unittest tool/design/test_check.py  (or python3 tool/design/test_check.py)"""
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check  # noqa: E402


def rules(rel, src):
    return sorted(r for r, _ in check.scan_file(rel, src))


class StripTest(unittest.TestCase):
    def test_comments_and_strings_blanked_length_kept(self):
        src = ("a(); // Color(0xFF000000)\n/* BoxShadow( /* nested */ TextStyle( */ b();\n"
               "x = 'Color(0x1)' + \"Colors.red\" + r'\\' + '''\nBoxShadow(\n''';\n")
        out = check.strip(src)
        self.assertEqual(len(out), len(src))
        self.assertEqual(out.count('\n'), src.count('\n'))
        for word in ('Color(', 'BoxShadow(', 'TextStyle(', 'Colors.'):
            self.assertNotIn(word, out)
        self.assertIn('a();', out)
        self.assertIn('b();', out)

    def test_interpolation_with_nested_strings_and_braces(self):
        src = "s = '${m['k'] ?? {'a': 1}} \\' ${x}'; Color(0xFF000000);"
        self.assertIn('Color(0xFF000000)', check.strip(src))

    def test_unterminated_single_line_string_stops_at_newline(self):
        self.assertIn('BoxShadow(', check.strip("x = 'oops\nBoxShadow();"))


class RuleTest(unittest.TestCase):
    def test_color_literal(self):
        src = ('final a = Color(0xFF000000); final b = Color.fromARGB(1, 2, 3, 4); final c = Color.fromRGBO(1, 2, 3, 1);'
               ' final d = Colors.red; final e = Colors.transparent; final f = DifyColors.textPrimary;'
               ' final g = DifyColor(0x1);')
        self.assertEqual(rules('a.dart', src), ['color-literal'] * 4)

    def test_box_shadow(self):
        self.assertEqual(rules('a.dart', 'const [BoxShadow(blurRadius: 1)]; DifyShadows.xs;'), ['box-shadow'])

    def test_raw_text_style_only_with_metrics(self):
        src = ('TextStyle(fontSize: 12); const TextStyle(color: c, fontStyle: FontStyle.italic);'
               ' TextStyle(color: f(height: 2)); TextStyle(\n  fontWeight: FontWeight.w500,\n);'
               ' difyTextStyle(DifyType.x, c); base.TextStyle(height: 1);'
               ' TextStyle(letterSpacing: 0, color: c);')
        self.assertEqual(rules('a.dart', src), ['raw-text-style'] * 3)

    def test_dialog_route_calls_only(self):
        src = ('showDialog<void>(context: c); showGeneralDialog(context: c); final showMenu = true;'
               ' if (showMenu) {} _showDialog(c); controller.showMenu();')
        self.assertEqual(rules('a.dart', src), ['dialog-route'] * 2)

    def test_material_widgets(self):
        src = ('Radio<String>(value: v); Tooltip(message: m); IconButton(onPressed: p); DifyIconButton();'
               ' DropdownButtonFormField(items: i); InputDecoration(); _Checkbox(); x.Switch();')
        self.assertEqual(rules('a.dart', src), ['material-widget'] * 6)

    def test_material_input_route_and_aliases_cannot_bypass_the_rule(self):
        src = 'TextField(); InputDecoration.collapsed(hintText: x); m.MaterialPageRoute<void>(builder: b); Scaffold(); DifyTextField();'
        self.assertEqual(rules('a.dart', src), ['material-widget'] * 4)

    def test_material_allowlist_waiver_is_invalid(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'allowlist.tsv'
            path.write_text('material-widget\ta.dart\t1\tdev-shell\n')
            _, errors = check.read_allowlist(path)
            self.assertTrue(any('prohibited' in e for e in errors))

    def test_css_focus_ring_requires_its_outside_only_decoration(self):
        for rel in ('studio/a.dart', 'design/widgets/a.dart'):
            self.assertEqual(rules(rel, 'BoxDecoration(boxShadow: difyFocusRing(focused));'), ['focus-ring'])
            self.assertEqual(rules(rel, 'DifyFocusDecoration(boxShadow: difyFocusRing(focused));'), [])

    def test_component_token(self):
        src = 'DifyColors.componentsCheckboxBgChecked; DifyColors.componentsPanelBg; DifyColors.componentsInputBgNormal;'
        self.assertEqual(rules('a.dart', src), ['component-token'] * 2)

    def test_dify_class(self):
        src = ('class DifyThing {} class DifyWorkflowEditor {} class DifyPromptEditorState {} class _DifyX {}'
               ' abstract final class DifyY {} enum DifyZ { a }')
        self.assertEqual(rules('a.dart', src), ['dify-class'] * 3)

    def test_design_files_only_checked_for_imports(self):
        src = ("import 'package:flutter/widgets.dart';\nimport '../dify_tokens.g.dart';\nimport '../../i18n/x.dart';\n"
               "import '../../workflow_editor/panel_fields/dialog.dart';\n"
               "import 'package:dify_sf_app/src/studio/a.dart';\n// import '../../cards/x.dart';\n"
               "class DifyX {} final c = Color(0xFF000000);\n")
        self.assertEqual(rules('design/widgets/a.dart', src), ['design-import'] * 2)

    def test_comment_and_string_hits_ignored(self):
        self.assertEqual(rules('a.dart', "// Color(0xFF000000)\nfinal s = 'BoxShadow(';\n/// [TextStyle(fontSize: 1)]\n"), [])


class RunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'app/lib/src/feature').mkdir(parents=True)
        (self.root / 'tool/design').mkdir(parents=True)
        self.allow = self.root / 'tool/design/allowlist.tsv'

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, src):
        p = self.root / 'app/lib/src' / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(src)

    def run_check(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        code = check.run(list(argv), root=self.root, out=out, err=err)
        return code, out.getvalue(), err.getvalue()

    def rows(self):
        return check.read_allowlist(self.allow)[0]

    def test_new_file_fails_with_location(self):
        self.write('feature/a.dart', 'x;\nfinal c = Color(0xFF000000);\n')
        code, _, err = self.run_check('--check')
        self.assertEqual(code, 1)
        self.assertIn('feature/a.dart:2 color-literal: final c = Color(0xFF000000);', err)

    def test_generated_files_skipped(self):
        self.write('feature/a.g.dart', 'final c = Color(0xFF000000);\n')
        self.assertEqual(self.run_check()[0], 0)

    def test_ratchet(self):
        self.write('feature/a.dart', 'Color(0x1); Color(0x2);')
        self.assertEqual(self.run_check('--update')[0], 1)  # no --allow-increase: nothing added
        self.assertEqual(self.rows(), {})
        code, _, _ = self.run_check('--update', '--allow-increase', '--reason', 'todo')
        self.assertEqual(code, 0)
        self.assertEqual(self.rows(), {('color-literal', 'feature/a.dart'): (2, 'todo:step4')})

        self.write('feature/a.dart', 'Color(0x1); Color(0x2); Color(0x3);')
        code, _, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('color-literal 3 > allowed 2', err)
        self.assertEqual(self.run_check('--update')[0], 1)  # --update never raises
        self.assertEqual(self.rows()[('color-literal', 'feature/a.dart')][0], 2)

        self.write('feature/a.dart', 'Color(0x1);')
        code, _, err = self.run_check()
        self.assertEqual(code, 1)
        self.assertIn('stale', err)
        self.assertEqual(self.run_check('--update')[0], 0)
        self.assertEqual(self.rows(), {('color-literal', 'feature/a.dart'): (1, 'todo:step4')})

        self.write('feature/a.dart', 'DifyColors.x;')
        self.assertEqual(self.run_check('--update')[0], 0)
        self.assertEqual(self.rows(), {})

    def test_raise_keeps_reason_new_row_gets_given_reason(self):
        self.write('feature/a.dart', 'Color(0x1);')
        self.allow.write_text('color-literal\tfeature/a.dart\t1\tthird-party:x\n')
        self.write('feature/a.dart', 'Color(0x1); Color(0x2); BoxShadow();')
        self.assertEqual(self.run_check('--update', '--allow-increase', '--reason', 'legit:why')[0], 0)
        self.assertEqual(self.rows(), {('box-shadow', 'feature/a.dart'): (1, 'legit:why'),
                                       ('color-literal', 'feature/a.dart'): (2, 'third-party:x')})

    def test_dev_shell_default_reason(self):
        self.write('editor/e.dart', 'showDialog(context: c);')
        self.run_check('--update', '--allow-increase', '--reason', 'todo')
        self.assertEqual(self.rows(), {('dialog-route', 'editor/e.dart'): (1, 'dev-shell')})

    def test_bad_rows(self):
        self.write('feature/a.dart', 'Color(0x1);')
        for text, msg in [('color-literal\tfeature/a.dart\t1\ttodo\n', 'reason'),
                          ('color-literal\tfeature/a.dart\t1\n', '4 tab-separated'),
                          ('nope\tfeature/a.dart\t1\tlegit:x\n', 'unknown rule'),
                          ('color-literal\tfeature/a.dart\tx\tlegit:x\n', 'positive integer'),
                          ('color-literal\tfeature/b.dart\t1\tlegit:x\ncolor-literal\tfeature/a.dart\t1\tlegit:x\n',
                           'not sorted')]:
            self.allow.write_text(text)
            code, _, err = self.run_check()
            self.assertEqual(code, 1, text)
            self.assertIn(msg, err)

    def test_allow_increase_needs_reason(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            check.run(['--update', '--allow-increase'], root=self.root, out=io.StringIO(), err=io.StringIO())


if __name__ == '__main__':
    unittest.main()
