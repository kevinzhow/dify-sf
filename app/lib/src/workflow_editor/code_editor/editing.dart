/// Monaco's typing behaviours for the code editor, as pure edits of a [TextEditingValue] against the [CodeDocument]
/// holding its text (Monaco 0.52.2 defaults: autoIndent 'full', autoClosingBrackets / autoClosingQuotes /
/// autoSurround 'languageDefined', autoClosingOvertype / autoClosingDelete 'auto', tabSize and insertSpaces from
/// indentation detection): the enter action (onEnterRules, bracket indent / indent-outdent), auto-closing pairs,
/// overtyping and deleting auto-closed characters, surrounding a selection, electric closing brackets, Tab /
/// Shift+Tab (`TypeOperations.tab`, `ShiftCommand`) and the line comment toggle.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'document.dart';
import 'language.dart';

/// The ranges of auto-inserted closing characters (Monaco's `autoClosedCharacters`): the opening character's offset
/// and the closing one's. They live while the cursor stays between them and move with edits.
class AutoClosedPairs {
  final _pairs = <(int open, int close)>[];

  /// Pairs added for the edit being applied; their offsets are already in the new text.
  final _pending = <(int open, int close)>[];

  bool get isEmpty => _pairs.isEmpty && _pending.isEmpty;

  Iterable<(int, int)> get _all => _pairs.followedBy(_pending);

  void add(int open, int close) => _pending.add((open, close));

  bool isAutoClosed(int closeOffset) => _all.any((p) => p.$2 == closeOffset);

  (int, int)? pairAround(int cursor) {
    for (final p in _all) {
      if (p.$1 + 1 == cursor && p.$2 == cursor) return p;
    }
    return null;
  }

  /// Moves the ranges by the edit from [oldText] to [newText] and drops those the [cursor] has left.
  void update(String oldText, String newText, int cursor) {
    if (_pairs.isNotEmpty && oldText != newText) {
      var prefix = 0;
      final minLen = math.min(oldText.length, newText.length);
      while (prefix < minLen && oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
        prefix++;
      }
      var suffix = 0;
      while (suffix < minLen - prefix &&
          oldText.codeUnitAt(oldText.length - 1 - suffix) == newText.codeUnitAt(newText.length - 1 - suffix)) {
        suffix++;
      }
      final oldEnd = oldText.length - suffix, delta = newText.length - oldText.length;
      final moved = <(int, int)>[];
      for (final (o, c) in _pairs) {
        int? shift(int x) => x < prefix ? x : (x >= oldEnd ? x + delta : null);
        final no = shift(o), nc = shift(c);
        if (no != null && nc != null) moved.add((no, nc));
      }
      _pairs
        ..clear()
        ..addAll(moved);
    }
    _pairs.addAll(_pending);
    _pending.clear();
    _pairs.removeWhere((p) => cursor <= p.$1 || cursor > p.$2);
  }

  void clear() {
    _pairs.clear();
    _pending.clear();
  }
}

String _leadingWhitespace(String s) {
  var i = 0;
  while (i < s.length && (s.codeUnitAt(i) == 32 || s.codeUnitAt(i) == 9)) {
    i++;
  }
  return s.substring(0, i);
}

const _wordSeparators = '`~!@#\$%^&*()-=+[{]}\\|;:\'",.<>/?';
const _autoCloseBeforeQuotes = ';:.,=}])> \n\t';
const _autoCloseBeforeBrackets = '\'"`;:.,=}])> \n\t';

class CodeEditing {
  CodeEditing(this.doc);
  final CodeDocument doc;

  CodeLanguage get _language => doc.language;

  /// `normalizeIndentation`.
  String normalizeIndentation(String str) {
    final ws = _leadingWhitespace(str);
    var columns = 0;
    for (final c in ws.codeUnits) {
      columns = c == 9 ? (columns ~/ doc.tabSize + 1) * doc.tabSize : columns + 1;
    }
    final buf = StringBuffer();
    if (!doc.insertSpaces) {
      buf.write('\t' * (columns ~/ doc.tabSize));
      columns %= doc.tabSize;
    }
    buf.write(' ' * columns);
    return '$buf${str.substring(ws.length)}';
  }

  ({int line, int column}) _pos(int offset) {
    final line = doc.lineAt(offset);
    return (line: line, column: offset - doc.lineStart(line));
  }

  static TextEditingValue _replace(TextEditingValue v, int start, int end, String text, int cursor) => TextEditingValue(
    text: v.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: cursor),
  );

  /// Applies Monaco's interceptors to typing [inserted] over [old]'s selection; null when plain insertion applies.
  /// [closed] tracks auto-closed characters.
  TextEditingValue? type(TextEditingValue old, String inserted, AutoClosedPairs closed) {
    final sel = old.selection;
    if (!sel.isValid) return null;
    if (inserted == '\n') return enter(old);
    if (inserted.length != 1) return null;
    final ch = inserted;
    if (sel.isCollapsed) {
      final offset = sel.baseOffset;
      // Overtype an auto-closed character.
      if (offset < old.text.length &&
          old.text[offset] == ch &&
          closed.isAutoClosed(offset) &&
          _language.autoClosingPairs.any((p) => p.close == ch)) {
        return old.copyWith(selection: TextSelection.collapsed(offset: offset + 1));
      }
      final close = _autoClosingPairClose(old.text, offset, ch);
      if (close != null) {
        if (close.length == 1) closed.add(offset, offset + 1);
        return _replace(old, offset, offset, ch + close, offset + 1);
      }
      return _electricChar(old, offset, ch);
    }
    return _surround(old, ch);
  }

  String? _autoClosingPairClose(String text, int offset, String ch) {
    AutoClosingPair? pair;
    for (final p in _language.autoClosingPairs) {
      if (!p.open.endsWith(ch)) continue;
      final before = p.open.substring(0, p.open.length - 1);
      if (offset >= before.length &&
          text.substring(offset - before.length, offset) == before &&
          (pair == null || p.open.length > pair.open.length)) {
        pair = p;
      }
    }
    if (pair == null) return null;
    final pos = _pos(offset);
    final lineText = doc.lines[pos.line];
    final lineBefore = lineText.substring(0, pos.column);
    final lineAfter = lineText.substring(pos.column);
    final isQuote = ch == '"' || ch == "'" || ch == '`';
    if (lineAfter.isNotEmpty) {
      final next = lineAfter[0];
      final pairs = _language.autoClosingPairs;
      final beforeClosing =
          !pairs.any((p) => p.open.startsWith(next) && lineAfter.startsWith(p.open)) &&
          pairs.any((p) => p.close.startsWith(next) && lineAfter.startsWith(p.close));
      if (!beforeClosing && !(isQuote ? _autoCloseBeforeQuotes : _autoCloseBeforeBrackets).contains(next)) return null;
    }
    if (pair.open.length == 1 && (ch == "'" || ch == '"') && lineBefore.isNotEmpty) {
      final before = lineBefore[lineBefore.length - 1];
      if (!_wordSeparators.contains(before) && before.trim().isNotEmpty) return null;
    }
    bool ok(StandardTokenType t) =>
        !(pair!.notInString && t == StandardTokenType.string) && !(pair.notInComment && t == StandardTokenType.comment);
    // `shouldAutoClose`: the token before the cursor; then the neutral-character probe.
    if (doc.tokensOf(pos.line).isNotEmpty && !ok(doc.tokenTypeAt(pos.line, math.max(0, pos.column - 1)))) return null;
    if (!ok(doc.tokenTypeIfInserting(pos.line, pos.column - (pair.open.length - 1), '0'))) return null;
    return pair.close;
  }

  /// Electric closing bracket: typed on a whitespace-only line prefix, the line takes the indentation of the line
  /// holding the matching opening bracket.
  TextEditingValue? _electricChar(TextEditingValue old, int offset, String ch) {
    final type = _language.brackets.indexWhere((b) => b.$2 == ch);
    if (type < 0) return null;
    final pos = _pos(offset);
    final lineText = doc.lines[pos.line];
    if (lineText.substring(0, pos.column).trim().isNotEmpty) return null;
    var depth = 0;
    for (var line = pos.line; line >= 0; line--) {
      final brackets = doc.bracketsOf(line);
      for (var i = brackets.length - 1; i >= 0; i--) {
        final b = brackets[i];
        if (b.type != type || (line == pos.line && b.column >= pos.column)) continue;
        if (!b.isOpen) {
          depth++;
        } else if (depth > 0) {
          depth--;
        } else {
          final indent = normalizeIndentation(_leadingWhitespace(doc.lines[line]));
          if (indent == lineText.substring(0, pos.column)) return null;
          final start = doc.lineStart(pos.line);
          return _replace(old, start, offset, indent + ch, start + indent.length + 1);
        }
      }
    }
    return null;
  }

  TextEditingValue? _surround(TextEditingValue old, String ch) {
    final pair = _language.surroundingPairs.where((p) => p.$1 == ch).firstOrNull;
    if (pair == null) return null;
    final sel = old.selection;
    final selected = old.text.substring(sel.start, sel.end);
    if (selected.trim().isEmpty) return null;
    return TextEditingValue(
      text: old.text.replaceRange(sel.start, sel.end, '${pair.$1}$selected${pair.$2}'),
      selection: TextSelection(baseOffset: sel.start + 1, extentOffset: sel.end + 1),
    );
  }

  /// Backspace with the cursor between an auto-closed pair deletes both characters.
  TextEditingValue? backspace(TextEditingValue old, AutoClosedPairs closed) {
    final sel = old.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final p = closed.pairAround(sel.baseOffset);
    if (p == null || p.$2 >= old.text.length) return null;
    final open = old.text[p.$1], close = old.text[p.$2];
    if (!_language.autoClosingPairs.any((x) => x.open == open && x.close == close)) return null;
    return _replace(old, p.$1, p.$2 + 1, '', p.$1);
  }

  /// Monaco's enter: `getEnterAction` (onEnterRules, then the bracket rules), else the line's indentation.
  TextEditingValue enter(TextEditingValue old) {
    final sel = old.selection;
    final start = _pos(sel.start), end = _pos(sel.end);
    final lineText = doc.lines[start.line];
    final before = lineText.substring(0, start.column);
    final after = doc.lines[end.line].substring(end.column);
    var indentation = _leadingWhitespace(lineText);
    if (indentation.length > start.column) indentation = indentation.substring(0, start.column);

    IndentAction? action;
    var appendText = '';
    var removeText = 0;
    for (final rule in _language.onEnterRules) {
      if (rule.beforeText.hasMatch(before) && (rule.afterText?.hasMatch(after) ?? true)) {
        action = rule.action;
        appendText = rule.appendText;
        removeText = rule.removeText;
        break;
      }
    }
    if (action == null && before.isNotEmpty) {
      for (final (open, close) in _language.brackets) {
        final openRe = RegExp('${RegExp.escape(open)}\\s*\$');
        if (!openRe.hasMatch(before)) continue;
        if (after.isNotEmpty && RegExp('^\\s*${RegExp.escape(close)}').hasMatch(after)) {
          action = IndentAction.indentOutdent;
          break;
        }
      }
      if (action == null) {
        for (final (open, _) in _language.brackets) {
          if (RegExp('${RegExp.escape(open)}\\s*\$').hasMatch(before)) {
            action = IndentAction.indent;
            break;
          }
        }
      }
    }
    String text;
    int cursor;
    if (action == null) {
      text = '\n${normalizeIndentation(indentation)}';
      cursor = sel.start + text.length;
    } else {
      if (appendText.isEmpty) {
        appendText = action == IndentAction.indent || action == IndentAction.indentOutdent ? '\t' : '';
      } else if (action == IndentAction.indent) {
        appendText = '\t$appendText';
      }
      if (removeText > 0) indentation = indentation.substring(0, math.max(0, indentation.length - removeText));
      switch (action) {
        case IndentAction.indentOutdent:
          final normal = normalizeIndentation(indentation);
          final increased = normalizeIndentation(indentation + appendText);
          text = '\n$increased\n$normal';
          cursor = sel.start + 1 + increased.length;
        case IndentAction.outdent:
          text = '\n${normalizeIndentation(_unshift(indentation) + appendText)}';
          cursor = sel.start + text.length;
        case IndentAction.none || IndentAction.indent:
          text = '\n${normalizeIndentation(indentation + appendText)}';
          cursor = sel.start + text.length;
      }
    }
    return _replace(old, sel.start, sel.end, text, cursor);
  }

  int _visibleColumn(String s) {
    var col = 0;
    for (final c in s.codeUnits) {
      col = c == 9 ? (col ~/ doc.tabSize + 1) * doc.tabSize : col + 1;
    }
    return col;
  }

  String _indentOfColumns(int columns) =>
      doc.insertSpaces ? ' ' * columns : '\t' * (columns ~/ doc.tabSize) + ' ' * (columns % doc.tabSize);

  String _unshift(String indentation) {
    final col = _visibleColumn(indentation);
    return _indentOfColumns(math.max(0, (col - 1) ~/ doc.tabSize * doc.tabSize));
  }

  /// Tab (`TypeOperations.tab`).
  TextEditingValue tab(TextEditingValue old) {
    final sel = old.selection;
    final start = _pos(sel.start), end = _pos(sel.end);
    if (sel.isCollapsed) {
      final lineText = doc.lines[start.line];
      if (lineText.trim().isEmpty) {
        final good = normalizeIndentation('\t');
        if (!lineText.startsWith(good)) {
          final ls = doc.lineStart(start.line);
          return _replace(old, ls, ls + lineText.length, good, ls + good.length);
        }
      }
      return _jumpToNextIndent(old);
    }
    if (start.line == end.line && (start.column != 0 || end.column != doc.lines[start.line].length)) {
      return _jumpToNextIndent(old);
    }
    return shift(old, unshift: false);
  }

  TextEditingValue _jumpToNextIndent(TextEditingValue old) {
    final sel = old.selection;
    final start = _pos(sel.start);
    String text;
    if (doc.insertSpaces) {
      final col = _visibleColumn(doc.lines[start.line].substring(0, start.column));
      text = ' ' * (doc.tabSize - col % doc.tabSize);
    } else {
      text = '\t';
    }
    return _replace(old, sel.start, sel.end, text, sel.start + text.length);
  }

  /// `ShiftCommand`: indents (or with [unshift], outdents) the selected lines by one indentation level.
  TextEditingValue shift(TextEditingValue old, {required bool unshift}) {
    final sel = old.selection;
    final first = doc.lineAt(sel.start);
    var last = doc.lineAt(sel.end);
    if (last > first && sel.end == doc.lineStart(last)) last--;
    final lines = [...doc.lines];
    final deltas = <int, (int, int)>{}; // line: (old indentation length, delta)
    for (var l = first; l <= last; l++) {
      final text = lines[l];
      final ws = _leadingWhitespace(text);
      if (unshift && (text.isEmpty || ws.isEmpty)) continue;
      if (!unshift && text.isEmpty) continue;
      final col = _visibleColumn(ws);
      final target = unshift
          ? math.max(0, (col - 1) ~/ doc.tabSize * doc.tabSize)
          : (col ~/ doc.tabSize + 1) * doc.tabSize;
      final indent = _indentOfColumns(target);
      lines[l] = indent + text.substring(ws.length);
      deltas[l] = (ws.length, indent.length - ws.length);
    }
    if (deltas.isEmpty) return old;
    int map(int offset) {
      final p = _pos(offset);
      var shiftBy = 0;
      for (final MapEntry(key: l, value: (wsLen, d)) in deltas.entries) {
        if (l < p.line) {
          shiftBy += d;
        } else if (l == p.line) {
          shiftBy += p.column >= wsLen ? d : math.max(d, -p.column);
        }
      }
      return offset + shiftBy;
    }

    // A selection starting within the first line's indentation keeps its start (`_selectionStartColumnStaysPut`).
    var start = map(sel.start);
    final firstDelta = deltas[first];
    if (!sel.isCollapsed && firstDelta != null && _pos(sel.start).column <= firstDelta.$1) {
      start = math.min(start, sel.start);
    }
    final end = map(sel.end);
    return TextEditingValue(
      text: lines.join('\n'),
      selection: sel.baseOffset <= sel.extentOffset
          ? TextSelection(baseOffset: start, extentOffset: end)
          : TextSelection(baseOffset: end, extentOffset: start),
    );
  }

  /// Toggle line comment (Ctrl+/): removes the language's line comment token from the selected lines when all
  /// non-empty ones have it, else inserts `token + ' '` at their smallest indentation.
  TextEditingValue toggleLineComment(TextEditingValue old) {
    final sel = old.selection;
    final token = _language.lineComment;
    final first = doc.lineAt(sel.start);
    var last = doc.lineAt(sel.end);
    if (last > first && sel.end == doc.lineStart(last)) last--;
    final lines = [...doc.lines];
    final targets = [
      for (var l = first; l <= last; l++)
        if (lines[l].trim().isNotEmpty) l,
    ];
    if (targets.isEmpty) targets.add(first);
    final remove = targets.every((l) => lines[l].trimLeft().startsWith(token));
    final minIndent = targets.map((l) => _leadingWhitespace(lines[l]).length).reduce(math.min);
    final edits = <int, (int at, int delta)>{};
    for (final l in targets) {
      final text = lines[l];
      if (remove) {
        final at = text.indexOf(token);
        var len = token.length;
        if (at + len < text.length && text[at + len] == ' ') len++;
        lines[l] = text.substring(0, at) + text.substring(at + len);
        edits[l] = (at, -len);
      } else {
        final at = math.min(minIndent, text.length);
        lines[l] = '${text.substring(0, at)}$token ${text.substring(at)}';
        edits[l] = (at, token.length + 1);
      }
    }
    // A non-empty selection grows over text inserted at its edges (`AlwaysGrowsWhenTypingAtEdges`).
    int map(int offset, {bool growsAtStart = false}) {
      final p = _pos(offset);
      var shiftBy = 0;
      for (final MapEntry(key: l, value: (at, d)) in edits.entries) {
        if (l < p.line) {
          shiftBy += d;
        } else if (l == p.line && (p.column > at || (p.column == at && !growsAtStart))) {
          shiftBy += d < 0 ? math.max(d, at - p.column) : d;
        }
      }
      return offset + shiftBy;
    }

    final start = map(sel.start, growsAtStart: !sel.isCollapsed), end = map(sel.end);
    return TextEditingValue(
      text: lines.join('\n'),
      selection: sel.baseOffset <= sel.extentOffset
          ? TextSelection(baseOffset: start, extentOffset: end)
          : TextSelection(baseOffset: end, extentOffset: start),
    );
  }
}
