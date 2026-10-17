/// Monaco's JavaScript language (monaco-editor 0.52.2, basic-languages/javascript/javascript.ts): TypeScript's
/// tokenizer (basic-languages/typescript/typescript.ts) with JavaScript's keywords, as Dart data.
library;

import 'monarch.dart';

const _typescriptTokenizer = <String, List<Object>>{
  'root': [MonarchRule(r'[{}]', 'delimiter.bracket'), MonarchInclude('common')],
  'common': [
    MonarchRule(r'#?[a-z_$][\w$]*', {
      'cases': {'@keywords': 'keyword', '@default': 'identifier'},
    }),
    MonarchRule(r'[A-Z][\w\$]*', 'type.identifier'),
    MonarchInclude('@whitespace'),
    MonarchRule(r'\/(?=([^\\\/]|\\.)+\/([dgimsuy]*)(\s*)(\.|;|,|\)|\]|\}|$))', {
      'token': 'regexp',
      'bracket': '@open',
      'next': '@regexp',
    }),
    MonarchRule(r'[()\[\]]', '@brackets'),
    MonarchRule(r'[<>](?!@symbols)', '@brackets'),
    MonarchRule(r'!(?=([^=]|$))', 'delimiter'),
    MonarchRule(r'@symbols', {
      'cases': {'@operators': 'delimiter', '@default': ''},
    }),
    MonarchRule(r'(@digits)[eE]([\-+]?(@digits))?', 'number.float'),
    MonarchRule(r'(@digits)\.(@digits)([eE][\-+]?(@digits))?', 'number.float'),
    MonarchRule(r'0[xX](@hexdigits)n?', 'number.hex'),
    MonarchRule(r'0[oO]?(@octaldigits)n?', 'number.octal'),
    MonarchRule(r'0[bB](@binarydigits)n?', 'number.binary'),
    MonarchRule(r'(@digits)n?', 'number'),
    MonarchRule(r'[;,.]', 'delimiter'),
    MonarchRule(r'"([^"\\]|\\.)*$', 'string.invalid'),
    MonarchRule(r"'([^'\\]|\\.)*$", 'string.invalid'),
    MonarchRule(r'"', 'string', '@string_double'),
    MonarchRule(r"'", 'string', '@string_single'),
    MonarchRule(r'`', 'string', '@string_backtick'),
  ],
  'whitespace': [
    MonarchRule(r'[ \t\r\n]+', ''),
    MonarchRule(r'\/\*\*(?!\/)', 'comment.doc', '@jsdoc'),
    MonarchRule(r'\/\*', 'comment', '@comment'),
    MonarchRule(r'\/\/.*$', 'comment'),
  ],
  'comment': [
    MonarchRule(r'[^\/*]+', 'comment'),
    MonarchRule(r'\*\/', 'comment', '@pop'),
    MonarchRule(r'[\/*]', 'comment'),
  ],
  'jsdoc': [
    MonarchRule(r'[^\/*]+', 'comment.doc'),
    MonarchRule(r'\*\/', 'comment.doc', '@pop'),
    MonarchRule(r'[\/*]', 'comment.doc'),
  ],
  'regexp': [
    MonarchRule(r'(\{)(\d+(?:,\d*)?)(\})', [
      'regexp.escape.control',
      'regexp.escape.control',
      'regexp.escape.control',
    ]),
    MonarchRule(r'(\[)(\^?)(?=(?:[^\]\\\/]|\\.)+)', [
      'regexp.escape.control',
      {'token': 'regexp.escape.control', 'next': '@regexrange'},
    ]),
    MonarchRule(r'(\()(\?:|\?=|\?!)', ['regexp.escape.control', 'regexp.escape.control']),
    MonarchRule(r'[()]', 'regexp.escape.control'),
    MonarchRule(r'@regexpctl', 'regexp.escape.control'),
    MonarchRule(r'[^\\\/]', 'regexp'),
    MonarchRule(r'@regexpesc', 'regexp.escape'),
    MonarchRule(r'\\\.', 'regexp.invalid'),
    MonarchRule(r'(\/)([dgimsuy]*)', [
      {'token': 'regexp', 'bracket': '@close', 'next': '@pop'},
      'keyword.other',
    ]),
  ],
  'regexrange': [
    MonarchRule(r'-', 'regexp.escape.control'),
    MonarchRule(r'\^', 'regexp.invalid'),
    MonarchRule(r'@regexpesc', 'regexp.escape'),
    MonarchRule(r'[^\]]', 'regexp'),
    MonarchRule(r'\]', {'token': 'regexp.escape.control', 'next': '@pop', 'bracket': '@close'}),
  ],
  'string_double': [
    MonarchRule(r'[^\\"]+', 'string'),
    MonarchRule(r'@escapes', 'string.escape'),
    MonarchRule(r'\\.', 'string.escape.invalid'),
    MonarchRule(r'"', 'string', '@pop'),
  ],
  'string_single': [
    MonarchRule(r"[^\\']+", 'string'),
    MonarchRule(r'@escapes', 'string.escape'),
    MonarchRule(r'\\.', 'string.escape.invalid'),
    MonarchRule(r"'", 'string', '@pop'),
  ],
  'string_backtick': [
    MonarchRule(r'\$\{', {'token': 'delimiter.bracket', 'next': '@bracketCounting'}),
    MonarchRule(r'[^\\`$]+', 'string'),
    MonarchRule(r'@escapes', 'string.escape'),
    MonarchRule(r'\\.', 'string.escape.invalid'),
    MonarchRule(r'`', 'string', '@pop'),
  ],
  'bracketCounting': [
    MonarchRule(r'\{', 'delimiter.bracket', '@bracketCounting'),
    MonarchRule(r'\}', 'delimiter.bracket', '@pop'),
    MonarchInclude('common'),
  ],
};

/// TypeScript's operators and shared regex attributes (javascript.ts takes them from typescript.ts).
const _typescriptAttributes = <String, Object>{
  'operators': [
    '<=', '>=', '==', '!=', '===', '!==', '=>', '+', '-', '**', '*', '/', '%', '++', '--', '<<', '</', '>>', //
    '>>>', '&', '|', '^', '!', '~', '&&', '||', '??', '?', ':', '=', '+=', '-=', '*=', '**=', '/=', '%=', '<<=',
    '>>=', '>>>=', '&=', '|=', '^=', '@',
  ],
  'symbols': r'[=><!~?:&|+\-*\/\^%]+',
  'escapes': r'''\\(?:[abfnrtv\\"']|x[0-9A-Fa-f]{1,4}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})''',
  'digits': r'\d+(_+\d+)*',
  'octaldigits': r'[0-7]+(_+[0-7]+)*',
  'binarydigits': r'[0-1]+(_+[0-1]+)*',
  'hexdigits': r'[[0-9a-fA-F]+(_+[0-9a-fA-F]+)*',
  'regexpctl': r'[(){}\[\]\$\^|\-*+?\.]',
  'regexpesc': r'\\(?:[bBdDfnrstvwWn0\\\/]|@regexpctl|c[A-Z]|x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4})',
};

const javascriptLanguage = MonarchDefinition(
  defaultToken: 'invalid',
  tokenPostfix: '.js',
  attributes: {
    'keywords': [
      'break', 'case', 'catch', 'class', 'continue', 'const', 'constructor', 'debugger', 'default', 'delete', 'do', //
      'else', 'export', 'extends', 'false', 'finally', 'for', 'from', 'function', 'get', 'if', 'import', 'in',
      'instanceof', 'let', 'new', 'null', 'return', 'set', 'static', 'super', 'switch', 'symbol', 'this', 'throw',
      'true', 'try', 'typeof', 'undefined', 'var', 'void', 'while', 'with', 'yield', 'async', 'await', 'of',
    ],
    'typeKeywords': <String>[],
    ..._typescriptAttributes,
  },
  tokenizer: _typescriptTokenizer,
);
