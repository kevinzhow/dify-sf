// Tokenizer outputs compared with Monaco's own: monaco_tokens.json was produced by running monaco-editor 0.52.2's
// Monarch compiler and lexer (python, javascript), its JSON mode tokenizer and the `vs` theme's TokenTheme over the
// snippets in it (token offsets, types, foreground colours and font styles per line).
import 'dart:convert';
import 'dart:io';

import 'package:dify_sf_app/src/workflow_editor/code_editor/language.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/monarch/monarch.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/monarch/vs_theme.dart';
import 'package:flutter_test/flutter_test.dart';

String _hex(TokenStyle s) => '#${(s.foreground.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

void main() {
  final fixture = jsonDecode(File('test/code_editor/monaco_tokens.json').readAsStringSync()) as Map<String, dynamic>;
  const languages = {'python': CodeLanguage.python3, 'javascript': CodeLanguage.javascript, 'json': CodeLanguage.json};

  for (final MapEntry(key: lang, value: snippets) in fixture.entries) {
    group('Monaco $lang tokens', () {
      for (final snippet in snippets as List) {
        test(snippet['name'] as String, () {
          final tokenizer = languages[lang]!.tokenizer;
          final lines = (snippet['text'] as String).split(RegExp(r'\r\n|\r|\n'));
          final expected = snippet['lines'] as List;
          var state = tokenizer.initialState;
          for (var i = 0; i < lines.length; i++) {
            final r = tokenizer.tokenize(lines[i], i < lines.length - 1, state);
            state = r.endState;
            final got = [
              for (final t in r.tokens)
                [t.offset, t.type, _hex(VsTheme.match(t.type)), VsTheme.match(t.type).italic ? 1 : 0],
            ];
            expect(got, expected[i], reason: 'line ${i + 1}: ${lines[i]}');
          }
        });
      }
    });
  }

  test('a line longer than Monaco\'s maxTokenizationLineLength is one plain token', () {
    final r = CodeLanguage.python3.tokenizer.tokenize('x' * 20000, false, CodeLanguage.python3.tokenizer.initialState);
    expect(r.tokens, [const Token(0, '')]);
  });

  test('states compare by value so re-tokenizing can stop early', () {
    final t = CodeLanguage.python3.tokenizer;
    final a = t.tokenize('x = """doc', true, t.initialState).endState;
    final b = t.tokenize('y = """other', true, t.initialState).endState;
    expect(a, b);
    expect(a, isNot(t.initialState));
  });
}
