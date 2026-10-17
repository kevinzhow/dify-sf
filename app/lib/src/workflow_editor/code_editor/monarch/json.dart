/// Monaco's JSON tokenizer (monaco-editor 0.52.2, language/json/tokenization.ts over jsonc-parser's scanner), which
/// Monaco registers for `json` with comments enabled, wrapped like `TokenizationSupportAdapter` (first token forced to
/// offset 0, offsets kept increasing, an end state equal to the start state replaced by it). Not Monarch: the JSON
/// mode is a hand-written tokens provider.
library;

import 'monarch.dart';

const _tokenDelimObject = 'delimiter.bracket.json';
const _tokenDelimArray = 'delimiter.array.json';
const _tokenDelimColon = 'delimiter.colon.json';
const _tokenDelimComma = 'delimiter.comma.json';
const _tokenValueBoolean = 'keyword.json';
const _tokenValueNull = 'keyword.json';
const _tokenValueString = 'string.value.json';
const _tokenValueNumber = 'number.json';
const _tokenPropertyName = 'string.key.json';
const _tokenCommentBlock = 'comment.block.json';
const _tokenCommentLine = 'comment.line.json';

// jsonc-parser SyntaxKind
const _openBrace = 1, _closeBrace = 2, _openBracket = 3, _closeBracket = 4, _comma = 5, _colon = 6;
const _nullKeyword = 7, _trueKeyword = 8, _falseKeyword = 9, _stringLiteral = 10, _numericLiteral = 11;
const _lineComment = 12, _blockComment = 13, _lineBreak = 14, _trivia = 15, _unknown = 16, _eof = 17;

// jsonc-parser ScanError
const _unexpectedEndOfComment = 1, _unexpectedEndOfString = 2, _unexpectedEndOfNumber = 3;
const _invalidUnicode = 4, _invalidEscapeCharacter = 5, _invalidCharacter = 6;

/// jsonc's `ParentsStack`: 0 = object, 1 = array.
class JsonParents {
  const JsonParents(this.parent, this.type);
  final JsonParents? parent;
  final int type;

  /// jsonc's `ParentsStack.equals`, including its quirk: stacks that agree up to the shorter one's end are equal.
  static bool equals(JsonParents? a, JsonParents? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    while (a != null && b != null) {
      if (identical(a, b)) return true;
      if (a.type != b.type) return false;
      a = a.parent;
      b = b.parent;
    }
    return true;
  }
}

class JsonState {
  const JsonState(this.scanError, this.lastWasColon, this._parents);
  final int? scanError;
  final bool lastWasColon;
  final JsonParents? _parents;

  @override
  bool operator ==(Object other) =>
      identical(other, this) ||
      other is JsonState &&
          scanError == other.scanError &&
          lastWasColon == other.lastWasColon &&
          JsonParents.equals(_parents, other._parents);

  @override
  int get hashCode => Object.hash(scanError, lastWasColon);
}

class JsonTokenizer implements TokenizationSupport {
  const JsonTokenizer();

  @override
  Object get initialState => const JsonState(null, false, null);

  @override
  LineTokens tokenize(String line, bool hasEOL, Object state) {
    final s = state as JsonState;
    final (tokens, endState) = _tokenize(line, s);
    // TokenizationSupportAdapter._toClassicTokens / adaptTokenize.
    final out = <Token>[];
    var previous = 0;
    for (var i = 0; i < tokens.length; i++) {
      var start = tokens[i].offset;
      if (i == 0) {
        start = 0;
      } else if (start < previous) {
        start = previous;
      }
      out.add(Token(start, tokens[i].type));
      previous = start;
    }
    return LineTokens(out, endState == s ? s : endState);
  }

  (List<Token>, JsonState) _tokenize(String line, JsonState state) {
    var inserted = 0;
    var adjustOffset = false;
    switch (state.scanError) {
      case _unexpectedEndOfString:
        line = '"$line';
        inserted = 1;
      case _unexpectedEndOfComment:
        line = '/*$line';
        inserted = 2;
    }
    final scanner = _Scanner(line);
    var lastWasColon = state.lastWasColon;
    var parents = state._parents;
    final tokens = <Token>[];
    var endState = JsonState(state.scanError, state.lastWasColon, state._parents);
    while (true) {
      var offset = scanner.pos;
      var type = '';
      final kind = scanner.scan();
      if (kind == _eof) break;
      if (offset == scanner.pos) throw StateError('Scanner did not advance');
      if (adjustOffset) offset -= inserted;
      adjustOffset = inserted > 0;
      switch (kind) {
        case _openBrace:
          parents = JsonParents(parents, 0);
          type = _tokenDelimObject;
          lastWasColon = false;
        case _closeBrace:
          parents = parents?.parent;
          type = _tokenDelimObject;
          lastWasColon = false;
        case _openBracket:
          parents = JsonParents(parents, 1);
          type = _tokenDelimArray;
          lastWasColon = false;
        case _closeBracket:
          parents = parents?.parent;
          type = _tokenDelimArray;
          lastWasColon = false;
        case _colon:
          type = _tokenDelimColon;
          lastWasColon = true;
        case _comma:
          type = _tokenDelimComma;
          lastWasColon = false;
        case _trueKeyword || _falseKeyword:
          type = _tokenValueBoolean;
          lastWasColon = false;
        case _nullKeyword:
          type = _tokenValueNull;
          lastWasColon = false;
        case _stringLiteral:
          final inArray = (parents?.type ?? 0) == 1;
          type = lastWasColon || inArray ? _tokenValueString : _tokenPropertyName;
          lastWasColon = false;
        case _numericLiteral:
          type = _tokenValueNumber;
          lastWasColon = false;
      }
      switch (kind) {
        case _lineComment:
          type = _tokenCommentLine;
        case _blockComment:
          type = _tokenCommentBlock;
      }
      endState = JsonState(scanner.scanError, lastWasColon, parents);
      tokens.add(Token(offset, type));
    }
    return (tokens, endState);
  }
}

/// jsonc-parser's `createScanner` (no trivia skipping), reduced to what tokenization reads.
class _Scanner {
  _Scanner(this.text) : len = text.length;
  final String text;
  final int len;
  int pos = 0;
  int scanError = 0;

  int _code(int i) => i < len ? text.codeUnitAt(i) : -1;

  static bool _isWhiteSpace(int ch) => ch == 32 || ch == 9;
  static bool _isLineBreak(int ch) => ch == 10 || ch == 13;
  static bool _isDigit(int ch) => ch >= 48 && ch <= 57;

  int _scanHexDigits(int count) {
    var digits = 0;
    var value = 0;
    while (digits < count) {
      final ch = _code(pos);
      if (ch >= 48 && ch <= 57) {
        value = value * 16 + ch - 48;
      } else if (ch >= 65 && ch <= 70) {
        value = value * 16 + ch - 65 + 10;
      } else if (ch >= 97 && ch <= 102) {
        value = value * 16 + ch - 97 + 10;
      } else {
        break;
      }
      pos++;
      digits++;
    }
    return digits < count ? -1 : value;
  }

  void _scanNumber() {
    if (_code(pos) == 48) {
      pos++;
    } else {
      pos++;
      while (pos < len && _isDigit(_code(pos))) {
        pos++;
      }
    }
    if (pos < len && _code(pos) == 46) {
      pos++;
      if (pos < len && _isDigit(_code(pos))) {
        pos++;
        while (pos < len && _isDigit(_code(pos))) {
          pos++;
        }
      } else {
        scanError = _unexpectedEndOfNumber;
        return;
      }
    }
    if (pos < len && (_code(pos) == 69 || _code(pos) == 101)) {
      pos++;
      if (pos < len && _code(pos) == 43 || _code(pos) == 45) pos++;
      if (pos < len && _isDigit(_code(pos))) {
        pos++;
        while (pos < len && _isDigit(_code(pos))) {
          pos++;
        }
      } else {
        scanError = _unexpectedEndOfNumber;
      }
    }
  }

  void _scanString() {
    while (true) {
      if (pos >= len) {
        scanError = _unexpectedEndOfString;
        break;
      }
      final ch = _code(pos);
      if (ch == 34) {
        pos++;
        break;
      }
      if (ch == 92) {
        pos++;
        if (pos >= len) {
          scanError = _unexpectedEndOfString;
          break;
        }
        final ch2 = _code(pos++);
        switch (ch2) {
          case 34 || 92 || 47 || 98 || 102 || 110 || 114 || 116:
            break;
          case 117:
            if (_scanHexDigits(4) < 0) scanError = _invalidUnicode;
          default:
            scanError = _invalidEscapeCharacter;
        }
        continue;
      }
      if (ch >= 0 && ch <= 31) {
        if (_isLineBreak(ch)) {
          scanError = _unexpectedEndOfString;
          break;
        } else {
          scanError = _invalidCharacter;
        }
      }
      pos++;
    }
  }

  static bool _isUnknownContentCharacter(int code) {
    if (_isWhiteSpace(code) || _isLineBreak(code)) return false;
    switch (code) {
      case 125 || 93 || 123 || 91 || 34 || 58 || 44 || 47:
        return false;
    }
    return true;
  }

  int scan() {
    scanError = 0;
    final tokenOffset = pos;
    if (pos >= len) return _eof;
    var code = _code(pos);
    if (_isWhiteSpace(code)) {
      do {
        pos++;
        code = _code(pos);
      } while (_isWhiteSpace(code));
      return _trivia;
    }
    if (_isLineBreak(code)) {
      pos++;
      if (code == 13 && _code(pos) == 10) pos++;
      return _lineBreak;
    }
    switch (code) {
      case 123:
        pos++;
        return _openBrace;
      case 125:
        pos++;
        return _closeBrace;
      case 91:
        pos++;
        return _openBracket;
      case 93:
        pos++;
        return _closeBracket;
      case 58:
        pos++;
        return _colon;
      case 44:
        pos++;
        return _comma;
      case 34:
        pos++;
        _scanString();
        return _stringLiteral;
      case 47:
        if (_code(pos + 1) == 47) {
          pos += 2;
          while (pos < len && !_isLineBreak(_code(pos))) {
            pos++;
          }
          return _lineComment;
        }
        if (_code(pos + 1) == 42) {
          pos += 2;
          final safeLength = len - 1;
          var closed = false;
          while (pos < safeLength) {
            final ch = _code(pos);
            if (ch == 42 && _code(pos + 1) == 47) {
              pos += 2;
              closed = true;
              break;
            }
            pos++;
            if (_isLineBreak(ch) && ch == 13 && _code(pos) == 10) pos++;
          }
          if (!closed) {
            pos++;
            scanError = _unexpectedEndOfComment;
          }
          return _blockComment;
        }
        pos++;
        return _unknown;
      case 45:
        pos++;
        if (pos == len || !_isDigit(_code(pos))) return _unknown;
        _scanNumber();
        return _numericLiteral;
      case >= 48 && <= 57:
        _scanNumber();
        return _numericLiteral;
      default:
        while (pos < len && _isUnknownContentCharacter(code)) {
          pos++;
          code = _code(pos);
        }
        if (tokenOffset != pos) {
          switch (text.substring(tokenOffset, pos)) {
            case 'true':
              return _trueKeyword;
            case 'false':
              return _falseKeyword;
            case 'null':
              return _nullKeyword;
          }
          return _unknown;
        }
        pos++;
        return _unknown;
    }
  }
}
