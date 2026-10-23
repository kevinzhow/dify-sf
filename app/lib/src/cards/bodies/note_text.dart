import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';

/// Lexical's text format bits (TextNode `format`).
abstract final class NoteFormat {
  static const bold = 1, italic = 2, strikethrough = 4, underline = 8;
}

/// The character that starts a bullet list item in [NoteText.text] (drawn as the item's disc).
const noteBullet = '';
const _bulletCode = 0xE000, _newline = 0x0A;

/// How a character of a note looks: Lexical's text format, its `font-size` style and the link it is in.
@immutable
class NoteStyle {
  const NoteStyle({this.format = 0, this.fontSize, this.url});
  static const plain = NoteStyle();

  final int format;

  /// `12px`, `14px`, `16px` (null: the paragraph's 12px).
  final String? fontSize;

  /// The URL of the link this character is in (`''` for a link being created).
  final String? url;

  bool has(int f) => format & f != 0;

  NoteStyle withFormat(int f, bool on) =>
      NoteStyle(format: on ? format | f : format & ~f, fontSize: fontSize, url: url);
  NoteStyle withFontSize(String? v) => NoteStyle(format: format, fontSize: v, url: url);
  NoteStyle withUrl(String? v) => NoteStyle(format: format, fontSize: fontSize, url: v);

  /// The text node's `style` (what `$patchStyleText` writes).
  String get css => fontSize == null ? '' : 'font-size: $fontSize;';

  @override
  bool operator ==(Object other) =>
      other is NoteStyle && other.format == format && other.fontSize == fontSize && other.url == url;

  @override
  int get hashCode => Object.hash(format, fontSize, url);
}

/// A note's content as one string: paragraphs separated by `\n`, bullet list items starting with [noteBullet], and
/// the style of every character. Read from and written to Dify's `data.text`, the Lexical editor state as JSON
/// (paragraphs, bullet lists, links, text with format bits and a `font-size` style).
@immutable
class NoteText {
  const NoteText(this.text, this.styles);
  static const empty = NoteText('', []);

  final String text;
  final List<NoteStyle> styles;

  /// No characters (Lexical's empty editor).
  bool get isEmpty => text.isEmpty;

  /// The note as Dify stores it: '' when empty, else `JSON.stringify(editorState)`.
  String toLexical() => text.isEmpty ? '' : jsonEncode({'root': _root(this)});

  /// [value] as stored by Dify; malformed or empty values are an empty note.
  factory NoteText.fromLexical(String? value) {
    if (value == null || value.isEmpty) return empty;
    Object? root;
    try {
      final parsed = jsonDecode(value);
      root = parsed is Map ? parsed['root'] : null;
    } on FormatException {
      return empty;
    }
    if (root is! Map) return empty;
    final b = _Reader();
    for (final c in _children(root)) {
      b.block(c);
    }
    return NoteText(b.text.toString(), b.styles);
  }
}

// ----- reading Lexical JSON -----

List<Map> _children(Map node) => [
  if (node['children'] case final List c)
    for (final x in c)
      if (x is Map) x,
];

class _Reader {
  final text = StringBuffer();
  final styles = <NoteStyle>[];
  bool _started = false, _bullet = false;

  void _add(String s, NoteStyle style) {
    text.write(s);
    styles.addAll(List.filled(s.length, style));
  }

  void _startBlock(bool bullet) {
    if (_started) _add('\n', NoteStyle.plain);
    _started = true;
    _bullet = bullet;
    if (bullet) _add(noteBullet, NoteStyle.plain);
  }

  void block(Map node) {
    switch (node['type']) {
      case 'list':
        for (final item in _children(node)) {
          _startBlock(true);
          for (final c in _children(item)) {
            c['type'] == 'list' ? block(c) : inline(c, null);
          }
        }
      case 'text' || 'link' || 'linebreak':
        _startBlock(false);
        inline(node, null);
      default:
        _startBlock(false);
        for (final c in _children(node)) {
          inline(c, null);
        }
    }
  }

  void inline(Map node, String? url) {
    switch (node['type']) {
      case 'text':
        final t = '${node['text'] ?? ''}'.replaceAll(noteBullet, '').replaceAll('\n', ' ');
        final size = RegExp(r'font-size:\s*([^;]+)').firstMatch('${node['style'] ?? ''}')?.group(1)?.trim();
        _add(t, NoteStyle(format: node['format'] is int ? node['format']! as int : 0, fontSize: size, url: url));
      case 'linebreak':
        _startBlock(_bullet);
      case 'tab':
        _add('\t', NoteStyle(url: url));
      case 'link' || 'autolink':
        for (final c in _children(node)) {
          inline(c, '${node['url'] ?? ''}');
        }
      default:
        for (final c in _children(node)) {
          inline(c, url);
        }
    }
  }
}

// ----- writing Lexical JSON (what Lexical 0.47's exportJSON gives) -----

Map<String, Object?> _element(String type, List<Object?> children, [Map<String, Object?> extra = const {}]) => {
  'children': children,
  'direction': children.isEmpty ? null : 'ltr',
  'format': '',
  'indent': 0,
  'type': type,
  'version': 1,
  ...extra,
};

Map<String, Object?> _textNode(String text, NoteStyle s) => {
  'detail': 0,
  'format': s.format,
  'mode': 'normal',
  'style': s.css,
  'text': text,
  'type': 'text',
  'version': 1,
};

/// The inline nodes of [start, end): text nodes per style, links around runs with the same URL.
List<Object?> _inlines(NoteText t, int start, int end) {
  final out = <Object?>[];
  List<Object?>? link;
  String? linkUrl;
  var i = start;
  while (i < end) {
    final s = t.styles[i];
    var j = i + 1;
    while (j < end && t.styles[j] == s) {
      j++;
    }
    final node = _textNode(t.text.substring(i, j), s.withUrl(null));
    if (s.url == null) {
      link = null;
      out.add(node);
    } else {
      if (link == null || linkUrl != s.url) {
        link = [];
        linkUrl = s.url;
        out.add(_element('link', link, {'rel': 'noreferrer', 'target': null, 'title': null, 'url': s.url}));
      }
      link.add(node);
    }
    i = j;
  }
  return out;
}

Map<String, Object?> _root(NoteText t) {
  final blocks = <Object?>[];
  List<Object?>? list;
  var start = 0;
  while (start <= t.text.length) {
    var end = t.text.indexOf('\n', start);
    if (end < 0) end = t.text.length;
    final bullet = end > start && t.text.codeUnitAt(start) == _bulletCode;
    final from = bullet ? start + 1 : start;
    final children = _inlines(t, from, end);
    if (bullet) {
      if (list == null) {
        list = [];
        blocks.add(_element('list', list, {'listType': 'bullet', 'start': 1, 'tag': 'ul'}));
      }
      list.add(_element('listitem', children, {'value': list.length + 1}));
    } else {
      list = null;
      final first = from < end ? t.styles[from].withUrl(null) : NoteStyle.plain;
      blocks.add(_element('paragraph', children, {'textFormat': first.format, 'textStyle': first.css}));
    }
    start = end + 1;
  }
  return _element('root', blocks);
}

// ----- drawing -----

/// note-editor/theme: 12 px paragraphs (line height 1.5, as the page's), `text-text-secondary`.
TextStyle get noteParagraphStyle => difyTextStyle(DifyTw.textXsLeading18, DifyColors.textSecondary);

/// `.note-editor-theme_link`: text-accent, weight 500, a 1 px underline in the accent at 60 %.
Color get _linkColor => DifyColors.textAccent;

double? _px(String? v) => v != null && v.endsWith('px') ? double.tryParse(v.substring(0, v.length - 2)) : null;

/// The style of a run: bold (`strong`: 700), italic, line-through, the font size, link colours.
TextStyle noteRunStyle(NoteStyle s) {
  final decorations = [
    if (s.has(NoteFormat.strikethrough)) TextDecoration.lineThrough,
    if (s.url != null) TextDecoration.underline,
  ];
  return TextStyle(
    fontSize: _px(s.fontSize),
    fontWeight: s.has(NoteFormat.bold)
        ? FontWeight.w700
        : s.url != null
        ? FontWeight.w500
        : null,
    fontStyle: s.has(NoteFormat.italic) ? FontStyle.italic : null,
    color: s.url != null ? _linkColor : null,
    decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
    decorationColor: s.url != null ? _linkColor.withValues(alpha: 0.6) : null,
    decorationThickness: 1,
  );
}

/// [t] as spans for a paragraph styled [noteParagraphStyle] (one span per run; [composing] underlined; each bullet
/// marker is the list item's disc, `margin-left: 18px` in front of its text).
TextSpan noteTextSpan(NoteText t, {TextRange composing = TextRange.empty}) {
  final children = <InlineSpan>[];
  void piece(int s, int e, TextStyle st) {
    if (e <= s) return;
    if (!composing.isValid || composing.start >= e || composing.end <= s) {
      children.add(TextSpan(text: t.text.substring(s, e), style: st));
      return;
    }
    final cs = composing.start.clamp(s, e), ce = composing.end.clamp(s, e);
    piece(s, cs, st);
    children.add(
      TextSpan(
        text: t.text.substring(cs, ce),
        style: st.merge(const TextStyle(decoration: TextDecoration.underline)),
      ),
    );
    piece(ce, e, st);
  }

  var i = 0;
  while (i < t.text.length) {
    final c = t.text.codeUnitAt(i);
    if (c == _bulletCode) {
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _Disc(fontSize: i + 1 < t.styles.length ? _px(t.styles[i + 1].fontSize) ?? 12 : 12),
        ),
      );
      i++;
      continue;
    }
    if (c == _newline) {
      children.add(const TextSpan(text: '\n'));
      i++;
      continue;
    }
    final s = t.styles[i];
    var j = i + 1;
    while (j < t.text.length && t.styles[j] == s) {
      final cj = t.text.codeUnitAt(j);
      if (cj == _bulletCode || cj == _newline) break;
      j++;
    }
    piece(i, j, noteRunStyle(s));
    i = j;
  }
  return TextSpan(style: noteParagraphStyle, children: children);
}

/// The list item's `disc` marker, outside its text: 18 px in front of it.
class _Disc extends StatelessWidget {
  const _Disc({required this.fontSize});
  final double fontSize;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 18,
    child: Padding(
      // Chrome's outside marker is the disc and a gap of about half an em.
      padding: EdgeInsets.only(right: fontSize / 2),
      child: DifyTextLine(
        '•',
        textAlign: TextAlign.right,
        style: noteParagraphStyle.copyWith(fontSize: fontSize),
      ),
    ),
  );
}
