/// The languages of Dify's code editor (`CodeLanguage` in nodes/code/types.ts, mapped to Monaco ids by `languageMap`
/// in code-editor/index.tsx) with the parts of Monaco's language configuration the editor acts on: brackets,
/// auto-closing pairs, line comments, enter rules and off-side folding (python.ts / typescript.ts `conf`, and
/// jsonMode's `richEditConfiguration`).
library;

import 'monarch/javascript.dart';
import 'monarch/json.dart';
import 'monarch/monarch.dart';
import 'monarch/python.dart';

enum IndentAction { none, indent, indentOutdent, outdent }

class OnEnterRule {
  const OnEnterRule(this.beforeText, this.action, {this.afterText, this.appendText = '', this.removeText = 0});
  final RegExp beforeText;
  final RegExp? afterText;
  final IndentAction action;
  final String appendText;
  final int removeText;
}

class AutoClosingPair {
  const AutoClosingPair(this.open, this.close, {this.notInString = false, this.notInComment = false});
  final String open, close;
  final bool notInString, notInComment;
}

enum CodeLanguage {
  python3('python', '#'),
  javascript('javascript', '//'),
  json('json', '//');

  const CodeLanguage(this.monacoId, this.lineComment);

  /// Dify's `languageMap` value.
  final String monacoId;
  final String lineComment;

  /// `CodeLanguage` from Dify's string value; anything else is JavaScript (`languageMap[language] || 'javascript'`).
  static CodeLanguage parse(String? value) => switch (value) {
    'python3' => python3,
    'json' => json,
    _ => javascript,
  };

  TokenizationSupport get tokenizer => switch (this) {
    python3 => _python,
    javascript => _javascript,
    json => const JsonTokenizer(),
  };

  List<(String, String)> get brackets => this == json ? const [('{', '}'), ('[', ']')] : _allBrackets;

  List<AutoClosingPair> get autoClosingPairs => switch (this) {
    python3 => const [
      AutoClosingPair('{', '}'),
      AutoClosingPair('[', ']'),
      AutoClosingPair('(', ')'),
      AutoClosingPair('"', '"', notInString: true),
      AutoClosingPair("'", "'", notInString: true, notInComment: true),
    ],
    javascript => const [
      AutoClosingPair('{', '}'),
      AutoClosingPair('[', ']'),
      AutoClosingPair('(', ')'),
      AutoClosingPair('"', '"', notInString: true),
      AutoClosingPair("'", "'", notInString: true, notInComment: true),
      AutoClosingPair('`', '`', notInString: true, notInComment: true),
      AutoClosingPair('/**', ' */', notInString: true),
    ],
    json => const [
      AutoClosingPair('{', '}', notInString: true),
      AutoClosingPair('[', ']', notInString: true),
      AutoClosingPair('"', '"', notInString: true),
    ],
  };

  /// `surroundingPairs` (defaults to the auto-closing pairs where a language has none).
  List<(String, String)> get surroundingPairs => switch (this) {
    python3 => const [('{', '}'), ('[', ']'), ('(', ')'), ('"', '"'), ("'", "'")],
    javascript => const [('{', '}'), ('[', ']'), ('(', ')'), ('"', '"'), ("'", "'"), ('`', '`')],
    json => const [('{', '}'), ('[', ']'), ('"', '"')],
  };

  List<OnEnterRule> get onEnterRules => switch (this) {
    python3 => _pythonEnterRules,
    javascript => _typescriptEnterRules,
    json => const [],
  };

  /// `folding.offSide`: blank lines belong to the region below (indent guides).
  bool get offSide => this == python3;
}

const _allBrackets = [('{', '}'), ('[', ']'), ('(', ')')];

final _python = MonarchTokenizer('python', pythonLanguage);
final _javascript = MonarchTokenizer('javascript', javascriptLanguage);

final _pythonEnterRules = [
  OnEnterRule(
    RegExp(r'^\s*(?:def|class|for|if|elif|else|while|try|with|finally|except|async|match|case).*?:\s*$'),
    IndentAction.indent,
  ),
];

final _typescriptEnterRules = [
  OnEnterRule(
    RegExp(r'^\s*\/\*\*(?!\/)([^\*]|\*(?!\/))*$'),
    IndentAction.indentOutdent,
    afterText: RegExp(r'^\s*\*\/$'),
    appendText: ' * ',
  ),
  OnEnterRule(RegExp(r'^\s*\/\*\*(?!\/)([^\*]|\*(?!\/))*$'), IndentAction.none, appendText: ' * '),
  OnEnterRule(RegExp(r'^(\t|(\ \ ))*\ \*(\ ([^\*]|\*(?!\/))*)?$'), IndentAction.none, appendText: '* '),
  OnEnterRule(RegExp(r'^(\t|(\ \ ))*\ \*\/\s*$'), IndentAction.none, removeText: 1),
];
