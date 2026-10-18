/// Monaco's built-in `vs` (light) theme, which Dify's code editor ends up with (it asks for the unknown theme 'light',
/// and Monaco falls back to `vs`; Dify defines no theme overrides for this editor): the token rules
/// (editor/standalone/common/themes.ts) resolved like Monaco's `TokenTheme` (dotted-prefix trie, rules sorted by
/// token), and the editor colours Monaco 0.52.2 registers for light themes.
library;

import 'dart:ui' show Color, FontStyle, FontWeight;

class TokenStyle {
  const TokenStyle(this.foreground, {this.italic = false, this.bold = false, this.underline = false});
  final Color foreground;
  final bool italic, bold, underline;

  FontStyle? get fontStyle => italic ? FontStyle.italic : null;
  FontWeight? get fontWeight => bold ? FontWeight.bold : null;
}

/// `vs.rules`, preceded by the `editor.foreground` rule Monaco adds for themes that define it.
const _vsRules = <(String token, String? foreground, String? fontStyle)>[
  ('', '000000', null), // editor.foreground
  ('', '000000', null),
  ('invalid', 'cd3131', null),
  ('emphasis', null, 'italic'),
  ('strong', null, 'bold'),
  ('variable', '001188', null),
  ('variable.predefined', '4864AA', null),
  ('constant', 'dd0000', null),
  ('comment', '008000', null),
  ('number', '098658', null),
  ('number.hex', '3030c0', null),
  ('regexp', '800000', null),
  ('annotation', '808080', null),
  ('type', '008080', null),
  ('delimiter', '000000', null),
  ('delimiter.html', '383838', null),
  ('delimiter.xml', '0000FF', null),
  ('tag', '800000', null),
  ('tag.id.pug', '4F76AC', null),
  ('tag.class.pug', '4F76AC', null),
  ('meta.scss', '800000', null),
  ('metatag', 'e00000', null),
  ('metatag.content.html', 'FF0000', null),
  ('metatag.html', '808080', null),
  ('metatag.xml', '808080', null),
  ('metatag.php', null, 'bold'),
  ('key', '863B00', null),
  ('string.key.json', 'A31515', null),
  ('string.value.json', '0451A5', null),
  ('attribute.name', 'FF0000', null),
  ('attribute.value', '0451A5', null),
  ('attribute.value.number', '098658', null),
  ('attribute.value.unit', '098658', null),
  ('attribute.value.html', '0000FF', null),
  ('attribute.value.xml', '0000FF', null),
  ('string', 'A31515', null),
  ('string.html', '0000FF', null),
  ('string.sql', 'FF0000', null),
  ('string.yaml', '0451A5', null),
  ('keyword', '0000FF', null),
  ('keyword.json', '0451A5', null),
  ('keyword.flow', 'AF00DB', null),
  ('keyword.flow.scss', '0000FF', null),
  ('operator.scss', '666666', null),
  ('operator.sql', '778899', null),
  ('operator.swift', '666666', null),
  ('predefined.sql', 'C700C7', null),
];

class _Rule {
  _Rule(this.fontStyle, this.foreground);
  int fontStyle; // -1 not set, else bits: 1 italic, 2 bold, 4 underline
  String foreground;
  _Rule clone() => _Rule(fontStyle, foreground);
}

class _Trie {
  _Trie(this.rule);
  final _Rule rule;
  final children = <String, _Trie>{};

  _Rule match(String token) {
    if (token.isEmpty) return rule;
    final dot = token.indexOf('.');
    final head = dot < 0 ? token : token.substring(0, dot);
    final child = children[head];
    return child == null ? rule : child.match(dot < 0 ? '' : token.substring(dot + 1));
  }

  void insert(String token, int fontStyle, String? foreground) {
    if (token.isEmpty) {
      if (fontStyle != -1) rule.fontStyle = fontStyle;
      if (foreground != null) rule.foreground = foreground;
      return;
    }
    final dot = token.indexOf('.');
    final head = dot < 0 ? token : token.substring(0, dot);
    final child = children.putIfAbsent(head, () => _Trie(rule.clone()));
    child.insert(dot < 0 ? '' : token.substring(dot + 1), fontStyle, foreground);
  }
}

int _parseFontStyle(String? s) {
  if (s == null) return -1;
  var r = 0;
  for (final seg in s.split(' ')) {
    r |= switch (seg) {
      'italic' => 1,
      'bold' => 2,
      'underline' => 4,
      _ => 0,
    };
  }
  return r;
}

/// The token colours of Monaco's `vs` theme.
abstract final class VsTheme {
  static final _Trie _root = () {
    final rules = [for (final (i, r) in _vsRules.indexed) (i, r)]
      ..sort((a, b) {
        final c = a.$2.$1.compareTo(b.$2.$1);
        return c != 0 ? c : a.$1 - b.$1;
      });
    var defaultFontStyle = 0;
    var defaultForeground = '000000';
    var i = 0;
    for (; i < rules.length && rules[i].$2.$1.isEmpty; i++) {
      final (_, fg, fs) = rules[i].$2;
      if (_parseFontStyle(fs) != -1) defaultFontStyle = _parseFontStyle(fs);
      if (fg != null) defaultForeground = fg;
    }
    final root = _Trie(_Rule(defaultFontStyle, defaultForeground));
    for (; i < rules.length; i++) {
      final (token, fg, fs) = rules[i].$2;
      root.insert(token, _parseFontStyle(fs), fg);
    }
    return root;
  }();

  static final _cache = <String, TokenStyle>{};

  /// The style of a token type such as `keyword.python` (`TokenTheme.match`).
  static TokenStyle match(String tokenType) => _cache.putIfAbsent(tokenType, () {
    final r = _root.match(tokenType);
    final fs = r.fontStyle < 0 ? 0 : r.fontStyle;
    return TokenStyle(
      Color(0xFF000000 | int.parse(r.foreground, radix: 16)),
      italic: fs & 1 != 0,
      bold: fs & 2 != 0,
      underline: fs & 4 != 0,
    );
  });

  // Editor colours (Monaco 0.52.2 colour registry, light defaults; `vs.colors`).
  static const foreground = Color(0xFF000000);
  static const selection = Color(0xFFADD6FF); // editor.selectionBackground
  static const inactiveSelection = Color(0xFFE5EBF1); // vs: editor.inactiveSelectionBackground
  static const cursor = Color(0xFF000000); // editorCursor.foreground
  static const lineHighlightBorder = Color(0xFFEEEEEE); // editor.lineHighlightBorder

  /// The overview ruler's border and cursor as Chrome shows them on Dify's light panels (`editorOverviewRuler.border`
  /// #7f7f7f4d drawn on the ruler's canvas; the cursor `editorCursor.foreground` at 0.7).
  static const overviewRulerBorder = Color(0x267F7F7F);
  static const overviewRulerCursor = Color(0xB3000000);
  static const lineNumber = Color(0xFF237893); // editorLineNumber.foreground
  static const activeLineNumber = Color(0xFF0B216F); // editorLineNumber.activeForeground
  static const indentGuide = Color(0xFFD3D3D3); // vs: editorIndentGuide.background1
  static const activeIndentGuide = Color(0xFF939393); // vs: editorIndentGuide.activeBackground1
  static const bracketMatchBackground = Color(0x1A006400); // editorBracketMatch.background
  static const bracketMatchBorder = Color(0xFFB9B9B9); // editorBracketMatch.border

  /// editorBracketHighlight.foreground1-3 (4-6 are transparent, so the colours cycle through these three).
  static const bracketColors = [Color(0xFF0431FA), Color(0xFF319331), Color(0xFF7B3814)];
  static const unexpectedBracket = Color.fromRGBO(255, 18, 18, 0.8);
  static const scrollbarShadow = Color(0xFFDDDDDD);
  static const scrollbarSlider = Color.fromRGBO(100, 100, 100, 0.4);
  static const scrollbarSliderHover = Color.fromRGBO(100, 100, 100, 0.7);
  static const scrollbarSliderActive = Color.fromRGBO(0, 0, 0, 0.6);
}
