import 'package:dify_sf_app/src/workflow_editor/code_editor/document.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/language.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _levels(CodeDocument d, int line) => [for (final b in d.bracketsOf(line)) b.level];

void main() {
  group('incremental tokenization', () {
    test('re-tokenizes only from the changed line until the state converges', () {
      final lines = [for (var i = 0; i < 200; i++) 'x$i = foo($i)  # c'];
      final doc = CodeDocument(CodeLanguage.python3, lines.join('\n'));
      final before = [for (var i = 0; i < 200; i++) doc.tokensOf(i)];
      lines[100] = 'y = bar(1)';
      expect(doc.setText(lines.join('\n')), 100);
      for (var i = 0; i < 200; i++) {
        if (i == 100) {
          expect(identical(doc.tokensOf(i), before[i]), isFalse);
        } else {
          expect(identical(doc.tokensOf(i), before[i]), isTrue, reason: 'line $i');
        }
      }
    });

    test('a state change carries on to the following lines', () {
      final doc = CodeDocument(CodeLanguage.python3, 'a = 1\nb = 2\nc = 3');
      doc.setText('a = """\nb = 2\nc = 3');
      expect(doc.tokensOf(1).single.type, 'string.python');
      expect(doc.tokensOf(2).single.type, 'string.python');
      doc.setText('a = 1\nb = 2\nc = 3');
      expect(doc.tokensOf(2).first.type, 'identifier.python');
    });

    test('inserting and deleting lines keeps the tokens of the unchanged tail', () {
      final doc = CodeDocument(CodeLanguage.javascript, 'const a = 1;\nlet b = "s";\n// end');
      final tail = doc.tokensOf(2);
      doc.setText('const a = 1;\nconst z = 0;\nlet b = "s";\n// end');
      expect(doc.lineCount, 4);
      expect(identical(doc.tokensOf(3), tail), isTrue);
      expect(doc.tokensOf(1).first.type, 'keyword.js');
    });
  });

  group('bracket pairs', () {
    test('colour levels follow nesting; brackets in strings and comments are ignored', () {
      final doc = CodeDocument(CodeLanguage.python3, 'f(a[1], {"k": "(x"})  # (y');
      expect(_levels(doc, 0), [0, 1, 1, 1, 1, 0]);
    });

    test('an unclosed bracket and a closing bracket without opener are invalid', () {
      final doc = CodeDocument(CodeLanguage.javascript, 'a(b[c)\n]');
      // `(` closes with `)`; the `[` inside stays unclosed; the last `]` closes nothing.
      expect(_levels(doc, 0), [0, -1, 0]);
      expect(_levels(doc, 1), [-1]);
    });

    test('JSON only pairs braces and square brackets', () {
      final doc = CodeDocument(CodeLanguage.json, '{"a": [1, 2]}');
      expect(_levels(doc, 0), [0, 1, 1, 0]);
    });

    test('matches the pair touching the cursor, else the enclosing pair', () {
      const text = 'foo(bar[1], baz)';
      final doc = CodeDocument(CodeLanguage.javascript, text);
      final open = text.indexOf('['), close = text.indexOf(']');
      expect((doc.matchBracket(open)!.open, doc.matchBracket(open)!.close), (open, close));
      // Between `]` and `,` the touching bracket is `]`.
      expect(doc.matchBracket(close + 1)!.open, open);
      final atComma = text.indexOf(',') + 1;
      expect(doc.matchBracket(atComma + 1), isNull);
      final enclosing = doc.enclosingBrackets(atComma + 1)!;
      expect((enclosing.open, enclosing.close), (3, text.length - 1));
    });
  });

  group('indent guides', () {
    test('levels per line, blank lines taking the surrounding level', () {
      final doc = CodeDocument(CodeLanguage.python3, 'def f():\n    if x:\n        y\n\n    return 1\n');
      expect(doc.indentGuides, [0, 1, 2, 1, 1, 0]);
    });

    test('the active guide is the block of the cursor line', () {
      final doc = CodeDocument(CodeLanguage.python3, 'def f():\n    if x:\n        y\n        z\n    return 1');
      expect(doc.activeIndentGuide(2), (startLine: 2, endLine: 3, indent: 2));
      // On a block's header the child block is active.
      expect(doc.activeIndentGuide(0), (startLine: 1, endLine: 4, indent: 1));
    });
  });

  group('indentation detection', () {
    test('two-space JSON gets tabSize 2', () {
      final doc = CodeDocument(CodeLanguage.json, '{\n  "a": {\n    "b": 1\n  }\n}');
      expect((doc.tabSize, doc.insertSpaces), (2, true));
    });

    test('four-space Python keeps 4, tab-indented code uses tabs', () {
      expect(CodeDocument(CodeLanguage.python3, 'def f():\n    return 1').tabSize, 4);
      expect(CodeDocument(CodeLanguage.python3, 'def f():\n\treturn 1\n\tpass').insertSpaces, isFalse);
    });
  });
}
