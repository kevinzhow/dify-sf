/// Monaco's Python language (monaco-editor 0.52.2, basic-languages/python/python.ts), as Dart data.
library;

import 'monarch.dart';

const pythonLanguage = MonarchDefinition(
  defaultToken: '',
  tokenPostfix: '.python',
  attributes: {
    'keywords': [
      'False', 'None', 'True', '_', 'and', 'as', 'assert', 'async', 'await', 'break', 'case', 'class', //
      'continue', 'def', 'del', 'elif', 'else', 'except', 'exec', 'finally', 'for', 'from', 'global', 'if',
      'import', 'in', 'is', 'lambda', 'match', 'nonlocal', 'not', 'or', 'pass', 'print', 'raise', 'return', 'try',
      'type', 'while', 'with', 'yield', 'int', 'float', 'long', 'complex', 'hex', 'abs', 'all', 'any', 'apply',
      'basestring', 'bin', 'bool', 'buffer', 'bytearray', 'callable', 'chr', 'classmethod', 'cmp', 'coerce',
      'compile', 'complex', 'delattr', 'dict', 'dir', 'divmod', 'enumerate', 'eval', 'execfile', 'file', 'filter',
      'format', 'frozenset', 'getattr', 'globals', 'hasattr', 'hash', 'help', 'id', 'input', 'intern', 'isinstance',
      'issubclass', 'iter', 'len', 'locals', 'list', 'map', 'max', 'memoryview', 'min', 'next', 'object', 'oct',
      'open', 'ord', 'pow', 'print', 'property', 'reversed', 'range', 'raw_input', 'reduce', 'reload', 'repr',
      'reversed', 'round', 'self', 'set', 'setattr', 'slice', 'sorted', 'staticmethod', 'str', 'sum', 'super',
      'tuple', 'type', 'unichr', 'unicode', 'vars', 'xrange', 'zip', '__dict__', '__methods__', '__members__',
      '__class__', '__bases__', '__name__', '__mro__', '__subclasses__', '__init__', '__import__',
    ],
  },
  brackets: [
    MonarchBracket('{', '}', 'delimiter.curly'),
    MonarchBracket('[', ']', 'delimiter.bracket'),
    MonarchBracket('(', ')', 'delimiter.parenthesis'),
  ],
  tokenizer: {
    'root': [
      MonarchInclude('@whitespace'),
      MonarchInclude('@numbers'),
      MonarchInclude('@strings'),
      MonarchRule(r'[,:;]', 'delimiter'),
      MonarchRule(r'[{}\[\]()]', '@brackets'),
      MonarchRule(r'@[a-zA-Z_]\w*', 'tag'),
      MonarchRule(r'[a-zA-Z_]\w*', {
        'cases': {'@keywords': 'keyword', '@default': 'identifier'},
      }),
    ],
    'whitespace': [
      MonarchRule(r'\s+', 'white'),
      MonarchRule(r'(^#.*$)', 'comment'),
      MonarchRule(r"'''", 'string', '@endDocString'),
      MonarchRule(r'"""', 'string', '@endDblDocString'),
    ],
    'endDocString': [
      MonarchRule(r"[^']+", 'string'),
      MonarchRule(r"\\'", 'string'),
      MonarchRule(r"'''", 'string', '@popall'),
      MonarchRule(r"'", 'string'),
    ],
    'endDblDocString': [
      MonarchRule(r'[^"]+', 'string'),
      MonarchRule(r'\\"', 'string'),
      MonarchRule(r'"""', 'string', '@popall'),
      MonarchRule(r'"', 'string'),
    ],
    'numbers': [
      MonarchRule(r'-?0x([abcdef]|[ABCDEF]|\d)+[lL]?', 'number.hex'),
      MonarchRule(r'-?(\d*\.)?\d+([eE][+\-]?\d+)?[jJ]?[lL]?', 'number'),
    ],
    'strings': [
      MonarchRule(r"'$", 'string.escape', '@popall'),
      MonarchRule(r"f'{1,3}", 'string.escape', '@fStringBody'),
      MonarchRule(r"'", 'string.escape', '@stringBody'),
      MonarchRule(r'"$', 'string.escape', '@popall'),
      MonarchRule(r'f"{1,3}', 'string.escape', '@fDblStringBody'),
      MonarchRule(r'"', 'string.escape', '@dblStringBody'),
    ],
    'fStringBody': [
      MonarchRule(r"[^\\'\{\}]+$", 'string', '@popall'),
      MonarchRule(r"[^\\'\{\}]+", 'string'),
      MonarchRule(r"\{[^\}':!=]+", 'identifier', '@fStringDetail'),
      MonarchRule(r'\\.', 'string'),
      MonarchRule(r"'", 'string.escape', '@popall'),
      MonarchRule(r'\\$', 'string'),
    ],
    'stringBody': [
      MonarchRule(r"[^\\']+$", 'string', '@popall'),
      MonarchRule(r"[^\\']+", 'string'),
      MonarchRule(r'\\.', 'string'),
      MonarchRule(r"'", 'string.escape', '@popall'),
      MonarchRule(r'\\$', 'string'),
    ],
    'fDblStringBody': [
      MonarchRule(r'[^\\"\{\}]+$', 'string', '@popall'),
      MonarchRule(r'[^\\"\{\}]+', 'string'),
      MonarchRule(r"\{[^\}':!=]+", 'identifier', '@fStringDetail'),
      MonarchRule(r'\\.', 'string'),
      MonarchRule(r'"', 'string.escape', '@popall'),
      MonarchRule(r'\\$', 'string'),
    ],
    'dblStringBody': [
      MonarchRule(r'[^\\"]+$', 'string', '@popall'),
      MonarchRule(r'[^\\"]+', 'string'),
      MonarchRule(r'\\.', 'string'),
      MonarchRule(r'"', 'string.escape', '@popall'),
      MonarchRule(r'\\$', 'string'),
    ],
    'fStringDetail': [
      MonarchRule(r'[:][^}]+', 'string'),
      MonarchRule(r'[!][ars]', 'string'),
      MonarchRule(r'=', 'string'),
      MonarchRule(r'\}', 'identifier', '@pop'),
    ],
  },
);
