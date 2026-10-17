/// A Dart port of Monaco's Monarch tokenizer (monaco-editor 0.52.2, editor/standalone/common/monarch: monarchCompile,
/// monarchLexer, monarchCommon), enough to run Monaco's own language definitions unchanged: states and dotted parent
/// states, regex rules with `@attribute` expansion, includes, `cases` (with `@keywords` lookups, `@eos`, `@default`,
/// `$n` / `$Sn` scrutinees and `~regex` / `==` guards), groups, `next` (`@push`, `@pop`, `@popall`, a state),
/// `switchTo`, `goBack`, `@rematch`, `@brackets`, `$n` token substitution, `tokenPostfix` and `defaultToken`.
/// Embedded languages (`nextEmbedded`) are not supported; no language Dify uses has them.
///
/// Definitions are written as data in the shape of Monaco's JSON ones: a rule is a [MonarchRule] or a
/// [MonarchInclude]; an action is a token `String`, a `Map` (`token`, `next`, `bracket`, `cases`, `switchTo`,
/// `goBack`) or a `List` of actions (a group). Regexes are JavaScript regex sources (Dart's RegExp shares the syntax).
library;

/// One token of a line: it starts at [offset] (UTF-16 index into the line) and runs to the next token.
class Token {
  const Token(this.offset, this.type);
  final int offset;
  final String type;

  @override
  bool operator ==(Object other) => other is Token && other.offset == offset && other.type == type;

  @override
  int get hashCode => Object.hash(offset, type);

  @override
  String toString() => '$offset:$type';
}

/// The tokens of one line and the state the next line starts in.
class LineTokens {
  const LineTokens(this.tokens, this.endState);
  final List<Token> tokens;
  final Object endState;
}

/// Monaco's `ITokenizationSupport` (classic tokens): tokenizes one line at a time, carrying a state.
abstract interface class TokenizationSupport {
  Object get initialState;

  /// Tokenizes [line] (without its line break; [hasEOL] tells whether one follows) starting in [state].
  LineTokens tokenize(String line, bool hasEOL, Object state);
}

class MonarchRule {
  const MonarchRule(this.regex, this.action, [this.next]);
  final String regex;

  /// A token `String`, an action `Map` or a group `List`.
  final Object? action;

  /// The rule's third element (`[regex, action, next]`).
  final String? next;
}

class MonarchInclude {
  const MonarchInclude(this.state);
  final String state;
}

class MonarchBracket {
  const MonarchBracket(this.open, this.close, this.token);
  final String open, close, token;
}

/// A Monarch language definition (`IMonarchLanguage`).
class MonarchDefinition {
  const MonarchDefinition({
    required this.tokenizer,
    this.tokenPostfix,
    this.defaultToken,
    this.ignoreCase = false,
    this.unicode = false,
    this.includeLF = false,
    this.start,
    this.brackets,
    this.attributes = const {},
  });

  /// State name to rules ([MonarchRule] or [MonarchInclude]), in Monaco's order.
  final Map<String, List<Object>> tokenizer;
  final String? tokenPostfix;
  final String? defaultToken;
  final bool ignoreCase, unicode, includeLF;
  final String? start;
  final List<MonarchBracket>? brackets;

  /// The definition's other attributes: word lists (`List<String>`, for `@keywords` cases) and regex sources
  /// (`String`, for `@symbols` in regexes).
  final Map<String, Object> attributes;
}

class MonarchError implements Exception {
  MonarchError(this.message);
  final String message;
  @override
  String toString() => 'MonarchError: $message';
}

/// The tokenizer's state stack (`MonarchStackElement`).
class MonarchStack {
  MonarchStack._(this.parent, this.state) : depth = (parent?.depth ?? 0) + 1;
  final MonarchStack? parent;
  final String state;
  final int depth;

  MonarchStack push(String state) => MonarchStack._(this, state);
  MonarchStack? pop() => parent;
  MonarchStack popAll() {
    var s = this;
    while (s.parent != null) {
      s = s.parent!;
    }
    return s;
  }

  MonarchStack switchTo(String state) => MonarchStack._(parent, state);

  @override
  bool operator ==(Object other) {
    if (other is! MonarchStack) return false;
    MonarchStack? a = this, b = other;
    while (a != null && b != null) {
      if (identical(a, b)) return true;
      if (a.state != b.state) return false;
      a = a.parent;
      b = b.parent;
    }
    return a == null && b == null;
  }

  @override
  int get hashCode => Object.hash(state, depth);

  @override
  String toString() => parent == null ? state : '$parent/$state';
}

typedef _Guard = bool Function(String id, List<String> matches, String state, bool eos);

sealed class _Action {}

/// A plain string action: used as is (no `$` substitution), as in Monaco.
class _StringAction extends _Action {
  _StringAction(this.token);
  final String token;
}

class _TokenAction extends _Action {
  _TokenAction(this.token, {this.subst = false, this.next, this.switchTo, this.goBack});
  final String token;
  final bool subst;
  final String? next, switchTo;
  final int? goBack;
}

class _GroupAction extends _Action {
  _GroupAction(this.group);
  final List<_Action> group;
}

class _CasesAction extends _Action {
  _CasesAction(this.cases, this.defaultToken);
  final List<(_Guard?, _Action)> cases;
  final String defaultToken;

  _Action test(String id, List<String> matches, String state, bool eos) {
    for (final (guard, value) in cases) {
      if (guard == null || guard(id, matches, state, eos)) return value;
    }
    return _StringAction(defaultToken);
  }
}

class _Rule {
  _Rule(this.name);
  String name;
  late final Object _regex; // RegExp, or RegExp Function(String state) for $Sn
  bool matchOnlyAtLineStart = false;
  late _Action action;

  RegExp resolve(String state) => _regex is RegExp ? _regex : (_regex as RegExp Function(String))(state);
}

/// A compiled Monarch tokenizer for one language.
class MonarchTokenizer implements TokenizationSupport {
  MonarchTokenizer(this.languageId, MonarchDefinition def)
    : _def = def,
      ignoreCase = def.ignoreCase,
      unicode = def.unicode,
      includeLF = def.includeLF,
      tokenPostfix = def.tokenPostfix ?? '.$languageId',
      defaultToken = def.defaultToken ?? 'source' {
    for (final entry in def.tokenizer.entries) {
      _start ??= def.start ?? entry.key;
      final rules = <_Rule>[];
      _addRules('tokenizer.${entry.key}', rules, entry.value);
      _tokenizer[entry.key] = rules;
    }
    _start ??= def.start;
    final brackets =
        def.brackets ??
        const [
          MonarchBracket('{', '}', 'delimiter.curly'),
          MonarchBracket('[', ']', 'delimiter.square'),
          MonarchBracket('(', ')', 'delimiter.parenthesis'),
          MonarchBracket('<', '>', 'delimiter.angle'),
        ];
    for (final b in brackets) {
      if (b.open == b.close) throw MonarchError('open and close brackets must be different: ${b.open}');
      _brackets.add((open: _fixCase(b.open), close: _fixCase(b.close), token: b.token + tokenPostfix));
    }
  }

  /// Monaco's `editor.maxTokenizationLineLength` default: longer lines get one plain token.
  static const maxTokenizationLineLength = 20000;

  final String languageId;
  final MonarchDefinition _def;
  final bool ignoreCase, unicode, includeLF;
  final String tokenPostfix, defaultToken;
  String? _start;
  final _tokenizer = <String, List<_Rule>>{};
  final _brackets = <({String open, String close, String token})>[];

  @override
  Object get initialState => MonarchStack._(null, _start!);

  String _fixCase(String s) => ignoreCase ? s.toLowerCase() : s;

  // ---- compilation (monarchCompile.ts)

  void _addRules(String state, List<_Rule> out, List<Object> rules) {
    for (final rule in rules) {
      if (rule is MonarchInclude) {
        var include = rule.state;
        if (include.startsWith('@')) include = include.substring(1);
        final target = _def.tokenizer[include];
        if (target == null) throw MonarchError("include target '$include' is not defined at: $state");
        _addRules('$state.$include', out, target);
        continue;
      }
      final r = rule as MonarchRule;
      final compiled = _Rule(state);
      final src = r.regex;
      compiled.matchOnlyAtLineStart = src.isNotEmpty && src[0] == '^';
      compiled.name = '${compiled.name}: $src';
      compiled._regex = _compileRegExp('^(?:${compiled.matchOnlyAtLineStart ? src.substring(1) : src})', true);
      Object? action = r.action;
      if (r.next != null) {
        if (action is String) {
          action = {'token': action, 'next': r.next};
        } else if (action is Map) {
          action = {...action, 'next': r.next};
        } else {
          throw MonarchError('a next state as the last element of a rule needs a string or object action: $state');
        }
      }
      compiled.action = _compileAction(compiled.name, action);
      out.add(compiled);
    }
  }

  String _expand(String str) {
    str = str.replaceAll('@@', '\x01');
    var n = 0;
    bool hadExpansion;
    do {
      hadExpansion = false;
      str = str.replaceAllMapped(RegExp(r'@(\w+)'), (m) {
        hadExpansion = true;
        final attr = _def.attributes[m[1]];
        if (attr is! String) {
          throw MonarchError(
            attr == null
                ? "language definition does not contain attribute '${m[1]}', used at: $str"
                : "attribute reference '${m[1]}' must be a string, used at: $str",
          );
        }
        return attr.isEmpty ? '' : '(?:$attr)';
      });
      n++;
    } while (hadExpansion && n < 5);
    return str.replaceAll('\x01', '@');
  }

  Object _compileRegExp(String str, bool handleSn) {
    str = _expand(str);
    RegExp make(String s) => RegExp(s, caseSensitive: !ignoreCase, unicode: unicode);
    if (handleSn && RegExp(r'\$[sS](\d\d?)').hasMatch(str)) {
      String? lastState;
      RegExp? last;
      return (String state) {
        if (last != null && lastState == state) return last!;
        lastState = state;
        return last = make(_substituteMatchesRe(str, state));
      };
    }
    return make(str);
  }

  _Action _compileAction(String ruleName, Object? action) {
    if (action == null) return _TokenAction('');
    if (action is String) return _StringAction(action);
    if (action is List) return _GroupAction([for (final a in action) _compileAction(ruleName, a)]);
    if (action is! Map) throw MonarchError('an action must be a string, an object or an array; in rule: $ruleName');
    if (action.containsKey('token')) {
      final token = action['token'];
      if (token is! String) throw MonarchError("a 'token' attribute must be of type string, in rule: $ruleName");
      String? next = action['next'] as String?;
      if (next != null && !const {'@pop', '@push', '@popall'}.contains(next)) {
        if (next.startsWith('@')) next = next.substring(1);
        if (!next.contains(r'$') && !_stateExists(_substituteMatches(next, '', const [], ''))) {
          throw MonarchError("the next state '${action['next']}' is not defined in rule: $ruleName");
        }
      }
      return _TokenAction(
        token,
        subst: token.contains(r'$'),
        next: next,
        switchTo: action['switchTo'] as String?,
        goBack: action['goBack'] as int?,
      );
    }
    final cases = action['cases'];
    if (cases is Map) {
      final compiled = <(_Guard?, _Action)>[];
      for (final MapEntry(:key, :value) in cases.entries) {
        final tkey = key as String;
        final val = _compileAction(ruleName, value);
        if (tkey == '@default' || tkey == '@' || tkey.isEmpty) {
          compiled.add((null, val));
        } else if (tkey == '@eos') {
          compiled.add(((id, matches, state, eos) => eos, val));
        } else {
          compiled.add((_createGuard(ruleName, tkey), val));
        }
      }
      return _CasesAction(compiled, defaultToken);
    }
    throw MonarchError("an action must have a 'token' or 'cases' attribute; in rule: $ruleName");
  }

  bool Function(String) _keywordMatcher(List<String> words) {
    final set = {for (final w in words) _fixCase(w)};
    return (w) => set.contains(_fixCase(w));
  }

  _Guard _createGuard(String ruleName, String tkey) {
    var scrut = -1; // -1: the matched text, 0-99: $n, 100+n: $Sn
    var oppat = tkey;
    final m = RegExp(r'^\$(([sS]?)(\d\d?)|#)(.*)$').firstMatch(tkey);
    if (m != null) {
      if (m[3] != null) {
        scrut = int.parse(m[3]!);
        if (m[2]!.isNotEmpty) scrut += 100;
      }
      oppat = m[4]!;
    }
    var op = '~';
    var pat = oppat;
    if (oppat.isEmpty) {
      op = '!=';
      pat = '';
    } else if (RegExp(r'^\w*$').hasMatch(pat)) {
      op = '==';
    } else {
      final om = RegExp(r'^(@|!@|~|!~|==|!=)(.*)$').firstMatch(oppat);
      if (om != null) {
        op = om[1]!;
        pat = om[2]!;
      }
    }
    bool Function(String s, String id, List<String> matches, String state) tester;
    if ((op == '~' || op == '!~') && RegExp(r'^(\w|\|)*$').hasMatch(pat)) {
      final inWords = _keywordMatcher(pat.split('|'));
      tester = (s, id, matches, state) => op == '~' ? inWords(s) : !inWords(s);
    } else if (op == '@' || op == '!@') {
      final words = _def.attributes[pat];
      if (words is! List<String>) {
        throw MonarchError("the @ match target '$pat' must be an array of strings, in rule: $ruleName");
      }
      final inWords = _keywordMatcher(words);
      tester = (s, id, matches, state) => op == '@' ? inWords(s) : !inWords(s);
    } else if (op == '~' || op == '!~') {
      if (!pat.contains(r'$')) {
        final re = _compileRegExp('^$pat\$', false) as RegExp;
        tester = (s, id, matches, state) => op == '~' ? re.hasMatch(s) : !re.hasMatch(s);
      } else {
        tester = (s, id, matches, state) {
          final re = _compileRegExp('^${_substituteMatches(pat, id, matches, state)}\$', false) as RegExp;
          return re.hasMatch(s);
        };
      }
    } else {
      final patx = _fixCase(pat);
      if (!pat.contains(r'$')) {
        tester = (s, id, matches, state) => op == '==' ? s == patx : s != patx;
      } else {
        tester = (s, id, matches, state) {
          final exp = _substituteMatches(patx, id, matches, state);
          return op == '==' ? s == exp : s != exp;
        };
      }
    }
    if (scrut == -1) return (id, matches, state, eos) => tester(id, id, matches, state);
    return (id, matches, state, eos) {
      final scrutinee = _selectScrutinee(id, matches, state, scrut);
      return tester(scrutinee ?? '', id, matches, state);
    };
  }

  static String? _selectScrutinee(String id, List<String> matches, String state, int num) {
    if (num < 0) return id;
    if (num < matches.length) return matches[num];
    if (num >= 100) {
      final parts = [state, ...state.split('.')];
      if (num - 100 < parts.length) return parts[num - 100];
    }
    return null;
  }

  bool _stateExists(String state) {
    String? s = state;
    while (s != null && s.isNotEmpty) {
      if (_def.tokenizer.containsKey(s)) return true;
      final i = s.lastIndexOf('.');
      s = i < 0 ? null : s.substring(0, i);
    }
    return false;
  }

  List<_Rule>? _findRules(String state) {
    String? s = state;
    while (s != null && s.isNotEmpty) {
      final rules = _tokenizer[s];
      if (rules != null) return rules;
      final i = s.lastIndexOf('.');
      s = i < 0 ? null : s.substring(0, i);
    }
    return null;
  }

  // ---- substitution (monarchCommon.ts)

  static final _substRe = RegExp(r'\$((\$)|(#)|(\d\d?)|[sS](\d\d?)|@(\w+))');

  String _substituteMatches(String str, String id, List<String> matches, String state) {
    List<String>? stateMatches;
    return str.replaceAllMapped(_substRe, (m) {
      if (m[2] != null) return r'$';
      if (m[3] != null) return _fixCase(id);
      if (m[4] != null) {
        final n = int.parse(m[4]!);
        if (n < matches.length) return _fixCase(matches[n]);
      }
      if (m[6] != null) {
        final attr = _def.attributes[m[6]];
        if (attr is String) return attr;
      }
      stateMatches ??= [state, ...state.split('.')];
      if (m[5] != null) {
        final s = int.parse(m[5]!);
        if (s < stateMatches!.length) return _fixCase(stateMatches![s]);
      }
      return '';
    });
  }

  String _substituteMatchesRe(String str, String state) {
    List<String>? stateMatches;
    return str.replaceAllMapped(RegExp(r'\$[sS](\d\d?)'), (m) {
      stateMatches ??= [state, ...state.split('.')];
      final s = int.parse(m[1]!);
      return s < stateMatches!.length ? _fixCase(stateMatches![s]) : '';
    });
  }

  static String _sanitize(String s) => s.replaceAll(RegExp(r'''[&<>'"_]'''), '-');

  // ---- lexing (monarchLexer.ts)

  @override
  LineTokens tokenize(String line, bool hasEOL, Object state) {
    final stack = state as MonarchStack;
    if (line.length >= maxTokenizationLineLength) return LineTokens([const Token(0, '')], state);
    try {
      return _tokenize(line, hasEOL, stack);
    } on MonarchError {
      // Monaco's safeTokenize: a throwing tokenizer yields one plain token and keeps the state.
      return LineTokens([const Token(0, '')], state);
    }
  }

  LineTokens _tokenize(String lineWithoutLF, bool hasEOL, MonarchStack stack) {
    final tokens = <Token>[];
    String? lastType;
    void emit(int offset, String type) {
      if (lastType == type) return;
      lastType = type;
      tokens.add(Token(offset, type));
    }

    final lineWithoutLFLength = lineWithoutLF.length;
    final line = hasEOL && includeLF ? '$lineWithoutLF\n' : lineWithoutLF;
    final lineLength = line.length;
    var pos = 0;
    List<String>? groupMatches;
    final groups = <({_Action action, String matched})>[];
    var forceEvaluation = true;

    while (forceEvaluation || pos < lineLength) {
      final pos0 = pos;
      final stackLen0 = stack.depth;
      final groupLen0 = groups.length;
      final state = stack.state;
      List<String>? matches;
      String? matched;
      _Action? action;
      _Rule? rule;

      if (groups.isNotEmpty) {
        matches = groupMatches;
        final entry = groups.removeAt(0);
        matched = entry.matched;
        action = entry.action;
      } else {
        if (!forceEvaluation && pos >= lineLength) break;
        forceEvaluation = false;
        final rules = _findRules(state);
        if (rules == null) throw MonarchError('tokenizer state is not defined: $state');
        final restOfLine = line.substring(pos);
        for (final r in rules) {
          if (pos == 0 || !r.matchOnlyAtLineStart) {
            final m = r.resolve(state).matchAsPrefix(restOfLine);
            if (m != null) {
              matches = [for (var i = 0; i <= m.groupCount; i++) m[i] ?? ''];
              matched = matches[0];
              action = r.action;
              rule = r;
              break;
            }
          }
        }
      }

      matches ??= [''];
      matched ??= '';
      if (action == null) {
        if (pos < lineLength) {
          matches = [line[pos]];
          matched = matches[0];
        }
        action = _StringAction(defaultToken);
      }

      pos += matched.length;

      while (action is _CasesAction) {
        action = action.test(matched, matches, state, pos == lineLength);
      }

      Object result; // String or List<_Action>
      switch (action!) {
        case _StringAction(:final token):
          result = token;
        case _GroupAction(:final group):
          result = group;
        case final _TokenAction a:
          result = a.subst ? _substituteMatches(a.token, matched, matches, state) : a.token;
          if (a.goBack != null && a.goBack != 0) pos = pos - a.goBack! < 0 ? 0 : pos - a.goBack!;
          if (a.switchTo != null) {
            var nextState = _substituteMatches(a.switchTo!, matched, matches, state);
            if (nextState.startsWith('@')) nextState = nextState.substring(1);
            if (_findRules(nextState) == null) {
              throw MonarchError("trying to switch to a state '$nextState' that is undefined in rule: ${rule?.name}");
            }
            stack = stack.switchTo(nextState);
          } else if (a.next != null) {
            switch (a.next) {
              case '@push':
                if (stack.depth >= 100) throw MonarchError('maximum tokenizer stack size reached');
                stack = stack.push(state);
              case '@pop':
                if (stack.depth <= 1) throw MonarchError('trying to pop an empty stack in rule: ${rule?.name}');
                stack = stack.pop()!;
              case '@popall':
                stack = stack.popAll();
              default:
                var nextState = _substituteMatches(a.next!, matched, matches, state);
                if (nextState.startsWith('@')) nextState = nextState.substring(1);
                if (_findRules(nextState) == null) {
                  throw MonarchError("trying to set a next state '$nextState' that is undefined");
                }
                stack = stack.push(nextState);
            }
          }
        case _CasesAction():
          throw StateError('unreachable');
      }

      if (result is List<_Action>) {
        if (groups.isNotEmpty) throw MonarchError('groups cannot be nested: ${rule?.name}');
        if (matches.length != result.length + 1) {
          throw MonarchError('matched number of groups does not match the number of actions in rule: ${rule?.name}');
        }
        var totalLen = 0;
        for (var i = 1; i < matches.length; i++) {
          totalLen += matches[i].length;
        }
        if (totalLen != matched.length) {
          throw MonarchError('with groups, all characters should be matched in consecutive groups: ${rule?.name}');
        }
        groupMatches = matches;
        for (var i = 0; i < result.length; i++) {
          groups.add((action: result[i], matched: matches[i + 1]));
        }
        pos -= matched.length;
        continue;
      }

      var token = result as String;
      if (token == '@rematch') {
        pos -= matched.length;
        matched = '';
        matches = null;
        token = '';
      }
      if (matched.isEmpty) {
        if (lineLength == 0 || stackLen0 != stack.depth || state != stack.state || groups.length != groupLen0) {
          continue;
        }
        throw MonarchError('no progress in tokenizer in rule: ${rule?.name}');
      }
      String tokenType;
      if (token.startsWith('@brackets')) {
        final rest = token.substring('@brackets'.length);
        final bracket = _findBracket(matched);
        if (bracket == null) throw MonarchError('@brackets token returned but no bracket defined as: $matched');
        tokenType = _sanitize(bracket + rest);
      } else {
        tokenType = _sanitize(token.isEmpty ? '' : token + tokenPostfix);
      }
      if (pos0 < lineWithoutLFLength) emit(pos0, tokenType);
    }
    return LineTokens(tokens, stack);
  }

  String? _findBracket(String matched) {
    if (matched.isEmpty) return null;
    matched = _fixCase(matched);
    for (final b in _brackets) {
      if (b.open == matched || b.close == matched) return b.token;
    }
    return null;
  }
}
