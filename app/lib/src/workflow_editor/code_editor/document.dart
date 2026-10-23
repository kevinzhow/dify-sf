/// The text model behind the code editor, doing what Monaco's TextModel does for rendering: line-by-line tokens with
/// carried state, re-tokenized from the first changed line until the state converges (Monaco's
/// TokenizationStateStore); bracket pairs as Monaco's bracket-pair AST sees them (brackets inside string, comment and
/// regex tokens ignored; unclosed and unexpected brackets invalid), for bracket colouring and matching; indent guides
/// (guidesTextModelPart.ts) and indentation detection (indentationGuesser.ts).
library;

import 'dart:math' as math;

import 'language.dart';
import 'monarch/monarch.dart';

/// Monaco's StandardTokenType, from the token type name (`toStandardTokenType`).
enum StandardTokenType { other, comment, string, regex }

final _standardTokenTypeRe = RegExp(r'\b(comment|string|regex|regexp)\b');

StandardTokenType standardTokenType(String type) => switch (_standardTokenTypeRe.firstMatch(type)?[1]) {
  'comment' => StandardTokenType.comment,
  'string' => StandardTokenType.string,
  'regex' || 'regexp' => StandardTokenType.regex,
  _ => StandardTokenType.other,
};

/// A bracket in a line: its column and, after pairing, its colour level or `-1` when invalid (unclosed, or closing
/// nothing).
class LineBracket {
  LineBracket(this.column, this.type, this.isOpen);
  final int column;
  final int type;
  final bool isOpen;
  int level = 0;
}

class BracketPair {
  const BracketPair(this.open, this.close);

  /// Document offsets of the opening and closing bracket characters.
  final int open, close;
}

/// Monaco's indent-guide model for a cursor line: the active guide spans [startLine]..[endLine] at [indent].
typedef ActiveIndentGuide = ({int startLine, int endLine, int indent});

class CodeDocument {
  CodeDocument(this.language, String text) {
    _setLines(_split(text), 0, 0);
    final guess = guessIndentation(_lines, defaultTabSize: 4, defaultInsertSpaces: true);
    tabSize = guess.tabSize;
    insertSpaces = guess.insertSpaces;
  }

  final CodeLanguage language;
  late int tabSize;
  late bool insertSpaces;

  var _lines = <String>[];
  var _lineStarts = <int>[];
  var _startStates = <Object>[];
  var _tokens = <List<Token>>[];
  var _brackets = <List<LineBracket>>[];
  var _pairs = <BracketPair>[];
  List<int>? _guides;
  String _text = '';

  /// Bumped on every change of text.
  int version = 0;

  String get text => _text;
  List<String> get lines => _lines;
  int get lineCount => _lines.length;
  List<Token> tokensOf(int line) => _tokens[line];
  List<LineBracket> bracketsOf(int line) => _brackets[line];
  Object startStateOf(int line) => _startStates[line];
  int lineStart(int line) => _lineStarts[line];
  int lineEnd(int line) => _lineStarts[line] + _lines[line].length;

  /// The line holding document [offset] (a line break belongs to the line it ends).
  int lineAt(int offset) {
    var lo = 0, hi = _lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  static List<String> _split(String text) => text.split(RegExp(r'\r\n|\r|\n'));

  /// Replaces the text; returns the first line whose tokens may have changed, or -1 when nothing changed.
  int setText(String text) {
    if (text == _text && _lines.isNotEmpty) return -1;
    final next = _split(text);
    final old = _lines;
    var prefix = 0;
    final minLen = math.min(old.length, next.length);
    while (prefix < minLen && old[prefix] == next[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < minLen - prefix && old[old.length - 1 - suffix] == next[next.length - 1 - suffix]) {
      suffix++;
    }
    // The last line's tokens never depend on its missing line break here (no language includes LF), so a line
    // moving into or out of the last position keeps its tokens.
    _setLines(next, prefix, suffix);
    _text = text;
    return prefix;
  }

  void _setLines(List<String> next, int prefix, int suffix) {
    final tokenizer = language.tokenizer;
    final oldLen = _lines.length;
    final oldStates = _startStates, oldTokens = _tokens, oldBrackets = _brackets;
    final states = <Object>[...oldStates.take(prefix)];
    final tokens = <List<Token>>[...oldTokens.take(prefix)];
    final brackets = <List<LineBracket>>[...oldBrackets.take(prefix)];
    var state = prefix == 0 ? tokenizer.initialState : _endStateAfter(prefix - 1, tokenizer);
    for (var i = prefix; i < next.length; i++) {
      final oldIndex = i - next.length + oldLen;
      if (i >= next.length - suffix && oldIndex >= prefix && oldStates[oldIndex] == state) {
        states.addAll(oldStates.skip(oldIndex));
        tokens.addAll(oldTokens.skip(oldIndex));
        brackets.addAll(oldBrackets.skip(oldIndex));
        break;
      }
      states.add(state);
      final r = tokenizer.tokenize(next[i], i < next.length - 1, state);
      tokens.add(r.tokens);
      brackets.add(_findBrackets(next[i], r.tokens));
      state = r.endState;
    }
    _lines = next;
    _startStates = states;
    _tokens = tokens;
    _brackets = brackets;
    _lineStarts = List<int>.filled(next.length, 0);
    for (var i = 1; i < next.length; i++) {
      _lineStarts[i] = _lineStarts[i - 1] + next[i - 1].length + 1;
    }
    _text = next.join('\n');
    _guides = null;
    version++;
    _pairBrackets();
  }

  Object _endStateAfter(int line, TokenizationSupport tokenizer) =>
      tokenizer.tokenize(_lines[line], true, _startStates[line]).endState;

  List<LineBracket> _findBrackets(String line, List<Token> tokens) {
    final pairs = language.brackets;
    List<LineBracket>? out;
    for (var t = 0; t < tokens.length; t++) {
      if (standardTokenType(tokens[t].type) != StandardTokenType.other) continue;
      final end = t + 1 < tokens.length ? tokens[t + 1].offset : line.length;
      for (var c = tokens[t].offset; c < end; c++) {
        final ch = line[c];
        for (var b = 0; b < pairs.length; b++) {
          if (pairs[b].$1 == ch || pairs[b].$2 == ch) {
            (out ??= []).add(LineBracket(c, b, pairs[b].$1 == ch));
            break;
          }
        }
      }
    }
    return out ?? const [];
  }

  /// Pairs brackets like Monaco's bracket-pair parser: a closing bracket closes the nearest open bracket of its
  /// type (open brackets above it stay unclosed) or, if none is open, is unexpected.
  void _pairBrackets() {
    final stack = <(LineBracket, int)>[];
    final pairs = <BracketPair>[];
    for (var line = 0; line < _brackets.length; line++) {
      for (final b in _brackets[line]) {
        final offset = _lineStarts[line] + b.column;
        if (b.isOpen) {
          b.level = stack.length;
          stack.add((b, offset));
          continue;
        }
        var j = stack.length - 1;
        while (j >= 0 && stack[j].$1.type != b.type) {
          j--;
        }
        if (j < 0) {
          b.level = -1;
          continue;
        }
        for (var k = j + 1; k < stack.length; k++) {
          stack[k].$1.level = -1;
        }
        b.level = j;
        pairs.add(BracketPair(stack[j].$2, offset));
        stack.length = j;
      }
    }
    for (final (b, _) in stack) {
      b.level = -1;
    }
    pairs.sort((a, b) => a.open - b.open);
    _pairs = pairs;
  }

  /// `bracketPairs.matchBracket`: the pair whose opening or closing bracket touches [offset] (the rightmost one).
  BracketPair? matchBracket(int offset) {
    BracketPair? best;
    var bestStart = -1;
    for (final p in _pairs) {
      if (p.open > offset) break;
      for (final s in [p.open, p.close]) {
        if (offset >= s && offset <= s + 1 && s >= bestStart) {
          best = p;
          bestStart = s;
        }
      }
    }
    if (best != null) return best;
    // Pairs opening before [offset] were all checked; a closing bracket touching it belongs to one of them.
    return null;
  }

  /// `bracketPairs.findEnclosingBrackets`: the innermost pair strictly containing [offset].
  BracketPair? enclosingBrackets(int offset) {
    BracketPair? best;
    for (final p in _pairs) {
      if (p.open >= offset) break;
      if (offset < p.close + 1) best = p;
    }
    return best;
  }

  /// The standard type of the token covering [column] of [line].
  StandardTokenType tokenTypeAt(int line, int column) {
    final tokens = _tokens[line];
    if (tokens.isEmpty) return StandardTokenType.other;
    var i = 0;
    while (i + 1 < tokens.length && tokens[i + 1].offset <= column) {
      i++;
    }
    return standardTokenType(tokens[i].type);
  }

  /// `getTokenTypeIfInsertingCharacter`: the type of the token [ch] would get if typed at [column] of [line].
  StandardTokenType tokenTypeIfInserting(int line, int column, String ch) {
    final text = _lines[line];
    final r = language.tokenizer.tokenize(
      text.substring(0, column) + ch + text.substring(column),
      line < _lines.length - 1,
      _startStates[line],
    );
    var type = '';
    for (final t in r.tokens) {
      if (t.offset > column) break;
      type = t.type;
    }
    return standardTokenType(type);
  }

  // ---- indent guides (guidesTextModelPart.ts)

  int _indentLevel(int line) => computeIndentLevel(_lines[line], tabSize);

  /// The number of indent guides of each line (`getLinesIndentGuides` over the whole document).
  List<int> get indentGuides => _guides ??= _computeIndentGuides();

  List<int> _computeIndentGuides() {
    final result = List<int>.filled(_lines.length, 0);
    var aboveIndex = -2, aboveIndent = -1, belowIndex = -2, belowIndent = -1;
    for (var line = 0; line < _lines.length; line++) {
      final indent = _indentLevel(line);
      if (indent >= 0) {
        aboveIndex = line;
        aboveIndent = indent;
        result[line] = (indent / tabSize).ceil();
        continue;
      }
      if (aboveIndex == -2) {
        aboveIndex = -1;
        aboveIndent = -1;
        for (var i = line - 1; i >= 0; i--) {
          final v = _indentLevel(i);
          if (v >= 0) {
            aboveIndex = i;
            aboveIndent = v;
            break;
          }
        }
      }
      if (belowIndex != -1 && (belowIndex == -2 || belowIndex < line)) {
        belowIndex = -1;
        belowIndent = -1;
        for (var i = line + 1; i < _lines.length; i++) {
          final v = _indentLevel(i);
          if (v >= 0) {
            belowIndex = i;
            belowIndent = v;
            break;
          }
        }
      }
      result[line] = _whitespaceLineIndentLevel(aboveIndent, belowIndent);
    }
    return result;
  }

  int _whitespaceLineIndentLevel(int above, int below) {
    if (above == -1 || below == -1) return 0;
    if (above < below) return 1 + above ~/ tabSize;
    if (above == below) return (below / tabSize).ceil();
    return language.offSide ? (below / tabSize).ceil() : 1 + below ~/ tabSize;
  }

  /// `getActiveIndentGuide` for [line] (0-based), searching the whole document.
  ActiveIndentGuide activeIndentGuide(int line) {
    final guides = indentGuides;
    final count = _lines.length;
    var startLine = 0, endLine = 0, indent = 0, initialIndent = 0;
    var goUp = true, goDown = true;
    for (var distance = 0; goUp || goDown; distance++) {
      final up = line - distance, down = line + distance;
      if (distance > 1 && up < 0) goUp = false;
      if (distance > 1 && down >= count) goDown = false;
      final upLevel = goUp && up >= 0 ? guides[up] : -1;
      final downLevel = goDown && down < count ? guides[down] : -1;
      if (distance == 0) {
        initialIndent = upLevel;
        continue;
      }
      if (distance == 1) {
        if (down < count && downLevel >= 0 && initialIndent + 1 == downLevel) {
          goUp = false;
          startLine = down;
          endLine = down;
          indent = downLevel;
          continue;
        }
        if (up >= 0 && upLevel >= 0 && upLevel - 1 == initialIndent) {
          goDown = false;
          startLine = up;
          endLine = up;
          indent = upLevel;
          continue;
        }
        startLine = line;
        endLine = line;
        indent = initialIndent;
        if (indent == 0) return (startLine: startLine, endLine: endLine, indent: indent);
      }
      if (goUp) {
        if (upLevel >= indent) {
          startLine = up;
        } else {
          goUp = false;
        }
      }
      if (goDown) {
        if (downLevel >= indent) {
          endLine = down;
        } else {
          goDown = false;
        }
      }
    }
    return (startLine: startLine, endLine: endLine, indent: indent);
  }
}

/// `computeIndentLevel`: the visible width of [line]'s leading whitespace, or -1 for a whitespace-only line.
int computeIndentLevel(String line, int tabSize) {
  var indent = 0;
  var i = 0;
  for (; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 32) {
      indent++;
    } else if (c == 9) {
      indent = indent - indent % tabSize + tabSize;
    } else {
      break;
    }
  }
  return i == line.length ? -1 : indent;
}

/// Monaco's `guessIndentation` (indentationGuesser.ts), which runs when the editor's model is created
/// (`detectIndentation`).
({int tabSize, bool insertSpaces}) guessIndentation(
  List<String> lines, {
  required int defaultTabSize,
  required bool defaultInsertSpaces,
}) {
  final linesCount = math.min(lines.length, 10000);
  var withTabs = 0, withSpaces = 0;
  var previousText = '';
  var previousIndentation = 0;
  const guesses = [2, 4, 6, 8, 3, 5, 7];
  final spacesDiffCount = List<int>.filled(9, 0);
  for (var n = 0; n < linesCount; n++) {
    final text = lines[n];
    var hasContent = false, indentation = 0, spaces = 0, tabs = 0;
    for (var j = 0; j < text.length; j++) {
      final c = text.codeUnitAt(j);
      if (c == 9) {
        tabs++;
      } else if (c == 32) {
        spaces++;
      } else {
        hasContent = true;
        indentation = j;
        break;
      }
    }
    if (!hasContent) continue;
    if (tabs > 0) {
      withTabs++;
    } else if (spaces > 1) {
      withSpaces++;
    }
    final (diff, looksLikeAlignment) = _spacesDiff(previousText, previousIndentation, text, indentation);
    if (looksLikeAlignment && !(defaultInsertSpaces && defaultTabSize == diff)) continue;
    if (diff <= 8) spacesDiffCount[diff]++;
    previousText = text;
    previousIndentation = indentation;
  }
  var insertSpaces = defaultInsertSpaces;
  if (withTabs != withSpaces) insertSpaces = withTabs < withSpaces;
  var tabSize = defaultTabSize;
  if (insertSpaces) {
    var score = 0;
    for (final t in guesses) {
      if (spacesDiffCount[t] > score) {
        score = spacesDiffCount[t];
        tabSize = t;
      }
    }
    if (tabSize == 4 &&
        spacesDiffCount[4] > 0 &&
        spacesDiffCount[2] > 0 &&
        spacesDiffCount[2] >= spacesDiffCount[4] / 2) {
      tabSize = 2;
    }
  }
  return (tabSize: tabSize, insertSpaces: insertSpaces);
}

(int, bool) _spacesDiff(String a, int aLength, String b, int bLength) {
  var i = 0;
  while (i < aLength && i < bLength && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  var aSpaces = 0, aTabs = 0, bSpaces = 0, bTabs = 0;
  for (var j = i; j < aLength; j++) {
    a.codeUnitAt(j) == 32 ? aSpaces++ : aTabs++;
  }
  for (var j = i; j < bLength; j++) {
    b.codeUnitAt(j) == 32 ? bSpaces++ : bTabs++;
  }
  if (aSpaces > 0 && aTabs > 0) return (0, false);
  if (bSpaces > 0 && bTabs > 0) return (0, false);
  final tabsDiff = (aTabs - bTabs).abs();
  final spacesDiff = (aSpaces - bSpaces).abs();
  if (tabsDiff == 0) {
    var alignment = false;
    if (spacesDiff > 0 && 0 <= bSpaces - 1 && bSpaces - 1 < a.length && bSpaces < b.length) {
      if (b.codeUnitAt(bSpaces) != 32 && a.codeUnitAt(bSpaces - 1) == 32 && a.codeUnitAt(a.length - 1) == 44) {
        alignment = true;
      }
    }
    return (spacesDiff, alignment);
  }
  if (spacesDiff % tabsDiff == 0) return (spacesDiff ~/ tabsDiff, false);
  return (0, false);
}
