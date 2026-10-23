import 'package:dify_sf_app/src/workflow_editor/code_editor/document.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/editing.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/language.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `|` marks the cursor, `[` `]` a selection (base, extent).
TextEditingValue _v(String marked) {
  final caret = marked.indexOf('|');
  if (caret >= 0) {
    return TextEditingValue(
      text: marked.replaceFirst('|', ''),
      selection: TextSelection.collapsed(offset: caret),
    );
  }
  final a = marked.indexOf('«'), b = marked.indexOf('»') - 1;
  return TextEditingValue(
    text: marked.replaceFirst('«', '').replaceFirst('»', ''),
    selection: TextSelection(baseOffset: a, extentOffset: b),
  );
}

String _show(TextEditingValue v) {
  final s = v.selection;
  if (s.isCollapsed) return v.text.replaceRange(s.baseOffset, s.baseOffset, '|');
  return v.text.replaceRange(s.end, s.end, '»').replaceRange(s.start, s.start, '«');
}

CodeEditing _editing(CodeLanguage l, TextEditingValue v) => CodeEditing(CodeDocument(l, v.text));

String _type(CodeLanguage l, String marked, String ch, [AutoClosedPairs? closed]) {
  final v = _v(marked);
  final r = _editing(l, v).type(v, ch, closed ?? AutoClosedPairs());
  if (r != null) return _show(r);
  final s = v.selection;
  return _show(
    TextEditingValue(
      text: v.text.replaceRange(s.start, s.end, ch),
      selection: TextSelection.collapsed(offset: s.start + ch.length),
    ),
  );
}

void main() {
  const py = CodeLanguage.python3, js = CodeLanguage.javascript, json = CodeLanguage.json;

  group('enter', () {
    test('keeps the indentation of the line', () {
      expect(_type(py, '    x = 1|', '\n'), '    x = 1\n    |');
    });

    test('indents after a Python block header (onEnterRules)', () {
      expect(_type(py, 'def main(a):|', '\n'), 'def main(a):\n    |');
      expect(_type(py, '    if a:|', '\n'), '    if a:\n        |');
    });

    test('indents after an open bracket and splits a bracket pair', () {
      expect(_type(js, 'function f() {|', '\n'), 'function f() {\n    |');
      expect(_type(js, 'const o = {|}', '\n'), 'const o = {\n    |\n}');
    });

    test('uses the detected indentation', () {
      expect(_type(json, '{\n  "a": [|]\n}', '\n'), '{\n  "a": [\n    |\n  ]\n}');
    });

    test('continues a JSDoc comment', () {
      expect(_type(js, '/**|', '\n'), '/**\n * |');
    });
  });

  group('auto-closing pairs', () {
    test('closes brackets and quotes before whitespace or a closing character', () {
      expect(_type(py, 'f|', '('), 'f(|)');
      expect(_type(py, 'x = |', '"'), 'x = "|"');
      expect(_type(js, 'a(|)', '['), 'a([|])');
    });

    test('does not close before a word, or a quote after a word character', () {
      expect(_type(py, 'f(|abc', '('), 'f((|abc');
      expect(_type(py, 'it|', "'"), "it'|");
    });

    test('does not close a quote that ends a string', () {
      expect(_type(py, 'x = "abc|', '"'), 'x = "abc"|');
    });

    test('types over and deletes an auto-closed character', () {
      final closed = AutoClosedPairs();
      final v1 = _v('f|');
      final e1 = _editing(py, v1);
      final v2 = e1.type(v1, '(', closed)!;
      expect(_show(v2), 'f(|)');
      final e2 = _editing(py, v2);
      expect(_show(e2.type(v2, ')', closed)!), 'f()|');
      expect(_show(e2.backspace(v2, closed)!), 'f|');
    });

    test('does not type over a closing character it did not insert', () {
      expect(_type(py, 'f(|)', ')'), 'f()|)');
    });

    test('surrounds a selection', () {
      expect(_type(py, 'x = «abc»', '('), 'x = («abc»)');
    });
  });

  test('a closing bracket typed on a blank prefix takes the opening line\'s indentation', () {
    expect(_type(js, 'if (a) {\n    x();\n    |', '}'), 'if (a) {\n    x();\n}|');
  });

  group('tab', () {
    TextEditingValue tab(CodeLanguage l, String m) => _editing(l, _v(m)).tab(_v(m));
    TextEditingValue shift(CodeLanguage l, String m, {bool unshift = false}) =>
        _editing(l, _v(m)).shift(_v(m), unshift: unshift);

    test('jumps to the next tab stop', () {
      expect(_show(tab(py, 'x = 1|')), 'x = 1   |');
      expect(_show(tab(py, '|')), '    |');
      expect(_show(tab(json, '{\n  "a": 1,\n|')), '{\n  "a": 1,\n  |');
    });

    test('indents and outdents selected lines', () {
      // A selection starting in the indentation keeps its start.
      expect(_show(shift(py, '«a\nb»')), '«    a\n    b»');
      expect(_show(shift(py, 'x\n    «a\n        b»', unshift: true)), 'x\n«a\n    b»');
      expect(_show(shift(py, '    a|', unshift: true)), 'a|');
    });
  });

  test('toggles line comments', () {
    TextEditingValue toggle(CodeLanguage l, String m) => _editing(l, _v(m)).toggleLineComment(_v(m));
    expect(_show(toggle(py, '    «a\n      b»')), '    «# a\n    #   b»');
    expect(_show(toggle(py, '    # a|')), '    a|');
    expect(_show(toggle(js, 'x|')), '// x|');
  });
}
