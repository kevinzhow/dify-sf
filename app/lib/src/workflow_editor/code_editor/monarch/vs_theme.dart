/// Monaco's built-in `vs` and `vs-dark` themes, which Dify's code editor ends up with (code-editor/index.tsx asks for
/// 'light', unknown, so Monaco falls back to `vs`, or `vs-dark` in the dark theme; Dify defines no theme overrides for
/// this editor): the token rules (editor/standalone/common/themes.ts) resolved like Monaco's `TokenTheme`
/// (dotted-prefix trie, rules sorted by token), and the editor colours Monaco 0.52.2 registers for light and dark
/// themes. [VsTheme] answers the current Dify theme's.
library;

import 'dart:ui' show Color, FontStyle, FontWeight;

import '../../../design/dify_tokens.g.dart' show DifyColors;

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

/// `vs_dark.rules`, preceded by the `editor.foreground` rule (`vs_dark.colors`).
const _vsDarkRules = <(String token, String? foreground, String? fontStyle)>[
  ('', 'D4D4D4', null), // editor.foreground
  ('', 'D4D4D4', null),
  ('invalid', 'f44747', null),
  ('emphasis', null, 'italic'),
  ('strong', null, 'bold'),
  ('variable', '74B0DF', null),
  ('variable.predefined', '4864AA', null),
  ('variable.parameter', '9CDCFE', null),
  ('constant', '569CD6', null),
  ('comment', '608B4E', null),
  ('number', 'B5CEA8', null),
  ('number.hex', '5BB498', null),
  ('regexp', 'B46695', null),
  ('annotation', 'cc6666', null),
  ('type', '3DC9B0', null),
  ('delimiter', 'DCDCDC', null),
  ('delimiter.html', '808080', null),
  ('delimiter.xml', '808080', null),
  ('tag', '569CD6', null),
  ('tag.id.pug', '4F76AC', null),
  ('tag.class.pug', '4F76AC', null),
  ('meta.scss', 'A79873', null),
  ('meta.tag', 'CE9178', null),
  ('metatag', 'DD6A6F', null),
  ('metatag.content.html', '9CDCFE', null),
  ('metatag.html', '569CD6', null),
  ('metatag.xml', '569CD6', null),
  ('metatag.php', null, 'bold'),
  ('key', '9CDCFE', null),
  ('string.key.json', '9CDCFE', null),
  ('string.value.json', 'CE9178', null),
  ('attribute.name', '9CDCFE', null),
  ('attribute.value', 'CE9178', null),
  ('attribute.value.number.css', 'B5CEA8', null),
  ('attribute.value.unit.css', 'B5CEA8', null),
  ('attribute.value.hex.css', 'D4D4D4', null),
  ('string', 'CE9178', null),
  ('string.sql', 'FF0000', null),
  ('keyword', '569CD6', null),
  ('keyword.flow', 'C586C0', null),
  ('keyword.json', 'CE9178', null),
  ('keyword.flow.scss', '569CD6', null),
  ('operator.scss', '909090', null),
  ('operator.sql', '778899', null),
  ('operator.swift', '909090', null),
  ('predefined.sql', 'FF00FF', null),
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

/// One of Monaco's built-in themes: token colours and the editor colours the code editor draws.
class MonacoTheme {
  MonacoTheme._(
    List<(String, String?, String?)> rules, {
    required this.foreground,
    required this.selection,
    required this.inactiveSelection,
    required this.cursor,
    required this.lineHighlightBorder,
    required this.overviewRulerBorder,
    required this.overviewRulerCursor,
    required this.lineNumber,
    required this.activeLineNumber,
    required this.indentGuide,
    required this.activeIndentGuide,
    required this.bracketMatchBackground,
    required this.bracketMatchBorder,
    required this.bracketColors,
    required this.unexpectedBracket,
    required this.scrollbarShadow,
    required this.scrollbarSlider,
    required this.scrollbarSliderHover,
    required this.scrollbarSliderActive,
  }) : _root = _trie(rules);

  static _Trie _trie(List<(String, String?, String?)> list) {
    final rules = [for (final (i, r) in list.indexed) (i, r)]
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
  }

  final _Trie _root;
  final _cache = <String, TokenStyle>{};

  /// The style of a token type such as `keyword.python` (`TokenTheme.match`).
  TokenStyle match(String tokenType) => _cache.putIfAbsent(tokenType, () {
    final r = _root.match(tokenType);
    final fs = r.fontStyle < 0 ? 0 : r.fontStyle;
    return TokenStyle(
      Color(0xFF000000 | int.parse(r.foreground, radix: 16)),
      italic: fs & 1 != 0,
      bold: fs & 2 != 0,
      underline: fs & 4 != 0,
    );
  });

  final Color foreground; // editor.foreground
  final Color selection; // editor.selectionBackground
  final Color inactiveSelection; // editor.inactiveSelectionBackground
  final Color cursor; // editorCursor.foreground
  final Color lineHighlightBorder; // editor.lineHighlightBorder

  /// The overview ruler's border and cursor as Chrome shows them on Dify's panels (`editorOverviewRuler.border`
  /// #7f7f7f4d drawn on the ruler's canvas; the cursor `editorCursor.foreground` at 0.7).
  final Color overviewRulerBorder, overviewRulerCursor;
  final Color lineNumber; // editorLineNumber.foreground
  final Color activeLineNumber; // editorLineNumber.activeForeground
  final Color indentGuide; // editorIndentGuide.background1
  final Color activeIndentGuide; // editorIndentGuide.activeBackground1
  final Color bracketMatchBackground; // editorBracketMatch.background
  final Color bracketMatchBorder; // editorBracketMatch.border

  /// editorBracketHighlight.foreground1-3 (4-6 are transparent, so the colours cycle through these three).
  final List<Color> bracketColors;
  final Color unexpectedBracket; // editorBracketHighlight.unexpectedBracket.foreground
  final Color scrollbarShadow, scrollbarSlider, scrollbarSliderHover, scrollbarSliderActive;

  /// `vs` (Monaco 0.52.2 colour registry, light defaults; `vs.colors`).
  static final vs = MonacoTheme._(
    _vsRules,
    foreground: const Color(0xFF000000),
    selection: const Color(0xFFADD6FF),
    inactiveSelection: const Color(0xFFE5EBF1), // vs.colors
    cursor: const Color(0xFF000000),
    lineHighlightBorder: const Color(0xFFEEEEEE),
    overviewRulerBorder: const Color(0x267F7F7F),
    overviewRulerCursor: const Color(0xB3000000),
    lineNumber: const Color(0xFF237893),
    activeLineNumber: const Color(0xFF0B216F),
    indentGuide: const Color(0xFFD3D3D3), // vs.colors
    activeIndentGuide: const Color(0xFF939393), // vs.colors
    bracketMatchBackground: const Color(0x1A006400),
    bracketMatchBorder: const Color(0xFFB9B9B9),
    bracketColors: const [Color(0xFF0431FA), Color(0xFF319331), Color(0xFF7B3814)],
    unexpectedBracket: const Color.fromRGBO(255, 18, 18, 0.8),
    scrollbarShadow: const Color(0xFFDDDDDD),
    scrollbarSlider: const Color.fromRGBO(100, 100, 100, 0.4),
    scrollbarSliderHover: const Color.fromRGBO(100, 100, 100, 0.7),
    scrollbarSliderActive: const Color.fromRGBO(0, 0, 0, 0.6),
  );

  /// `vs-dark` (Monaco 0.52.2 colour registry, dark defaults; `vs_dark.colors`).
  static final vsDark = MonacoTheme._(
    _vsDarkRules,
    foreground: const Color(0xFFD4D4D4), // vs_dark.colors
    selection: const Color(0xFF264F78),
    inactiveSelection: const Color(0xFF3A3D41), // vs_dark.colors
    cursor: const Color(0xFFAEAFAD),
    lineHighlightBorder: const Color(0xFF282828),
    overviewRulerBorder: const Color(0x267F7F7F),
    overviewRulerCursor: const Color(0xB3AEAFAD),
    lineNumber: const Color(0xFF858585),
    activeLineNumber: const Color(0xFFC6C6C6),
    indentGuide: const Color(0xFF404040), // vs_dark.colors
    activeIndentGuide: const Color(0xFF707070), // vs_dark.colors
    bracketMatchBackground: const Color(0x1A006400),
    bracketMatchBorder: const Color(0xFF888888),
    bracketColors: const [Color(0xFFFFD700), Color(0xFFDA70D6), Color(0xFF179FFF)],
    unexpectedBracket: const Color.fromRGBO(255, 18, 18, 0.8),
    scrollbarShadow: const Color(0xFF000000),
    scrollbarSlider: const Color.fromRGBO(121, 121, 121, 0.4),
    scrollbarSliderHover: const Color.fromRGBO(100, 100, 100, 0.7),
    scrollbarSliderActive: const Color.fromRGBO(191, 191, 191, 0.4),
  );

  /// The current Dify theme's: `vs-dark` in dark, else `vs`.
  static MonacoTheme get current => DifyColors.isDark ? vsDark : vs;
}

/// The current theme's token and editor colours ([MonacoTheme.current]).
abstract final class VsTheme {
  static MonacoTheme get _t => MonacoTheme.current;

  /// The style of a token type such as `keyword.python` (`TokenTheme.match`).
  static TokenStyle match(String tokenType) => _t.match(tokenType);

  static Color get foreground => _t.foreground;
  static Color get selection => _t.selection;
  static Color get inactiveSelection => _t.inactiveSelection;
  static Color get cursor => _t.cursor;
  static Color get lineHighlightBorder => _t.lineHighlightBorder;
  static Color get overviewRulerBorder => _t.overviewRulerBorder;
  static Color get overviewRulerCursor => _t.overviewRulerCursor;
  static Color get lineNumber => _t.lineNumber;
  static Color get activeLineNumber => _t.activeLineNumber;
  static Color get indentGuide => _t.indentGuide;
  static Color get activeIndentGuide => _t.activeIndentGuide;
  static Color get bracketMatchBackground => _t.bracketMatchBackground;
  static Color get bracketMatchBorder => _t.bracketMatchBorder;
  static List<Color> get bracketColors => _t.bracketColors;
  static Color get unexpectedBracket => _t.unexpectedBracket;
  static Color get scrollbarShadow => _t.scrollbarShadow;
  static Color get scrollbarSlider => _t.scrollbarSlider;
  static Color get scrollbarSliderHover => _t.scrollbarSliderHover;
  static Color get scrollbarSliderActive => _t.scrollbarSliderActive;
}
