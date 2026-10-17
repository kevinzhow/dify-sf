import 'package:collab_client/collab_client.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_graph.dart';
import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import '../card_kit.dart';
import 'note_text.dart';

/// note-node/constants.ts THEME_MAP (light): the colour picker's ring ([outer]), the title strip and swatch ([title]),
/// the card ([bg]) and its border while selected ([border]).
enum NoteTheme {
  blue(
    DifyColors.utilColorsBlueBlue500,
    DifyColors.utilColorsBlueBlue100,
    DifyColors.utilColorsBlueBlue50,
    DifyColors.utilColorsBlueBlue300,
  ),
  cyan(
    DifyColors.utilColorsCyanCyan500,
    DifyColors.utilColorsCyanCyan100,
    DifyColors.utilColorsCyanCyan50,
    DifyColors.utilColorsCyanCyan300,
  ),
  green(
    DifyColors.utilColorsGreenGreen500,
    DifyColors.utilColorsGreenGreen100,
    DifyColors.utilColorsGreenGreen50,
    DifyColors.utilColorsGreenGreen300,
  ),
  yellow(
    DifyColors.utilColorsYellowYellow500,
    DifyColors.utilColorsYellowYellow100,
    DifyColors.utilColorsYellowYellow50,
    DifyColors.utilColorsYellowYellow300,
  ),
  pink(
    DifyColors.utilColorsPinkPink500,
    DifyColors.utilColorsPinkPink100,
    DifyColors.utilColorsPinkPink50,
    DifyColors.utilColorsPinkPink300,
  ),
  // Dify's violet card is violet-100, not 50.
  violet(
    DifyColors.utilColorsVioletViolet500,
    DifyColors.utilColorsVioletViolet100,
    DifyColors.utilColorsVioletViolet100,
    DifyColors.utilColorsVioletViolet300,
  );

  const NoteTheme(this.outer, this.title, this.bg, this.border);
  final Color outer, title, bg, border;

  static NoteTheme of(Object? name) => values.where((t) => t.name == name).firstOrNull ?? blue;
}

/// React Flow's node type of notes (note-node/constants.ts CUSTOM_NOTE_NODE).
const customNoteNode = 'custom-note';

/// NodeResizer's limits for notes.
const noteMinWidth = 240.0, noteMinHeight = 88.0;

/// Whether [n] is a note (React Flow type `custom-note`, kept in `_dify_node`).
bool isNoteCard(Node n) => switch (n.config['_dify_node']) {
  VMap(:final entries) => entries['type'] == const VString(customNoteNode),
  _ => false,
};

/// A note's data (note-node/types.ts NoteNodeType): `text` (Lexical JSON), `theme`, `author`, `showAuthor`, and the
/// card's `width` and `height`.
@immutable
class NoteData {
  const NoteData({
    this.text = '',
    this.theme = NoteTheme.blue,
    this.author = '',
    this.showAuthor = true,
    this.width = noteMinWidth,
    this.height = noteMinHeight,
    this.temp = false,
  });

  final String text;
  final NoteTheme theme;
  final String author;
  final bool showAuthor;
  final double width, height;

  /// `_isTempNode`: shown, not editable.
  final bool temp;

  Size get size => Size(width, height);

  static double _num(Object? v, double fallback) => switch (v) {
    VInt(:final value) => value.toDouble(),
    VDouble(:final value) => value,
    num n => n.toDouble(),
    _ => fallback,
  };

  static String _str(Object? v) => switch (v) {
    VString(:final value) => value,
    String s => s,
    _ => '',
  };

  factory NoteData.of(Node n) {
    final c = n.config;
    return NoteData(
      text: _str(c['text']),
      theme: NoteTheme.of(_str(c['theme'])),
      author: _str(c['author']),
      showAuthor: c['showAuthor'] != const VBool(false),
      width: _num(c['width'], noteMinWidth),
      height: _num(c['height'], noteMinHeight),
    );
  }

  /// From Dify's node `data` (a candidate note).
  factory NoteData.fromJson(Map data) => NoteData(
    text: _str(data['text']),
    theme: NoteTheme.of(data['theme']),
    author: _str(data['author']),
    showAuthor: data['showAuthor'] != false,
    width: _num(data['width'], noteMinWidth),
    height: _num(data['height'], noteMinHeight),
    temp: data['_isTempNode'] == true,
  );
}

/// Text styled by Dify's tokens alone: notes, their toolbar and popups are drawn where no Material text theme is
/// (on the canvas, in the overlay).
class NoteTextScope extends StatelessWidget {
  const NoteTextScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: TextStyle(
      fontFamily: cardFontFamily,
      fontSize: 14,
      height: 20 / 14,
      letterSpacing: 0,
      wordSpacing: 0,
      color: DifyColors.textPrimary,
      leadingDistribution: TextLeadingDistribution.even,
    ),
    child: child,
  );
}

/// The placeholder (prompt-editor Placeholder `compact`: 13 px, leading 20 px).
TextStyle get notePlaceholderStyle => TextStyle(
  fontFamily: cardFontFamily,
  fontSize: 13,
  height: 20 / 13,
  leadingDistribution: TextLeadingDistribution.even,
  color: DifyColors.componentsInputTextPlaceholder,
);

/// The author line: `text-xs text-text-tertiary`.
TextStyle get noteAuthorStyle => TextStyle(
  fontFamily: cardFontFamily,
  fontSize: 12,
  height: 16 / 12,
  leadingDistribution: TextLeadingDistribution.even,
  color: DifyColors.textTertiary,
);

/// Where the editor sits in a note of [data] (inside the border, below the strip, `px-3 py-2.5`, above the author
/// line `p-3 pt-0`).
Rect noteEditorRect(NoteData data) {
  final author = data.showAuthor ? textHeight(data.author, noteAuthorStyle, data.width - 2 - 24) + 12 : 0.0;
  return Rect.fromLTRB(13, 19, data.width - 13, data.height - 11 - author);
}

/// note-node/index.tsx: `group relative flex flex-col rounded-md border shadow-xs hover:shadow-md` in the theme's
/// background (the theme's border while selected, else black/5), the `h-2 opacity-50` title strip, the editor area
/// (`grow px-3 py-2.5`) and the author line. [editor] replaces the read-only text (the live editor of a selected
/// note); [shadow] false leaves the shadow to the card underneath.
class NoteCardView extends StatelessWidget {
  const NoteCardView({
    super.key,
    required this.data,
    this.hovered = false,
    this.selected = false,
    this.shadow = true,
    this.editor,
  });

  final NoteData data;
  final bool hovered, selected, shadow;
  final Widget? editor;

  static const _unselectedBorder = Color(0x0D000000);

  @override
  Widget build(BuildContext context) {
    final t = data.theme;
    final text = NoteText.fromLexical(data.text);
    return NoteTextScope(
      child: SizedBox.fromSize(
        size: data.size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: t.bg,
            borderRadius: BorderRadius.circular(DifyRadius.md),
            border: Border.all(color: selected ? t.border : _unselectedBorder),
            boxShadow: shadow ? (hovered ? DifyShadows.md : DifyShadows.xs) : null,
          ),
          child: Padding(
            padding: const EdgeInsets.all(1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: t.title.withValues(alpha: t.title.a * 0.5),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(DifyRadius.md)),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child:
                        editor ??
                        ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            maxHeight: double.infinity,
                            child: text.isEmpty
                                ? Text(
                                    DifyI18n.tr('workflow', 'nodes.note.editor.placeholder'),
                                    style: notePlaceholderStyle,
                                  )
                                : Text.rich(noteTextSpan(text)),
                          ),
                        ),
                  ),
                ),
                if (data.showAuthor)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: data.author.isEmpty ? null : Text(data.author, style: noteAuthorStyle),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The resizer's glyph (note-node/index.tsx Icon, 18 px, black/16), drawn at the bottom-right corner where the
/// resize button sits; the canvas card shows it on hover, the selected note's editor over it.
class NoteResizeGlyph extends StatelessWidget {
  const NoteResizeGlyph({super.key});

  @override
  Widget build(BuildContext context) => const CustomPaint(size: Size.square(18), painter: _GlyphPainter());
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(12, 9.75)
      ..lineTo(12, 6)
      ..lineTo(13.5, 6)
      ..lineTo(13.5, 9.75)
      ..cubicTo(13.5, 11.8211, 11.8211, 13.5, 9.75, 13.5)
      ..lineTo(6, 13.5)
      ..lineTo(6, 12)
      ..lineTo(9.75, 12)
      ..cubicTo(10.9926, 12, 12, 10.9926, 12, 9.75)
      ..close();
    canvas.drawPath(p, Paint()..color = const Color(0x29000000));
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => false;
}

/// NodeResizer's button: `absolute right-px bottom-px` (md, 24 px) inside React Flow's 4 px bottom-right control
/// centred on the corner, so it ends 1 px outside the card. Relative to the card's top-left.
Rect noteResizeButton(Size card) => Rect.fromLTWH(card.width - 23, card.height - 23, 24, 24);

/// The note on the canvas, read-only (a selected note is edited in an overlay over it, see NoteNodeOverlay). The
/// resize glyph shows on hover (`group-hover:opacity-100`).
class NoteCard extends StatelessWidget {
  const NoteCard({super.key, required this.node, this.onPainted});

  final CanvasNode node;
  final VoidCallback? onPainted;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([node.node, node.hovered]),
    builder: (context, _) {
      if (onPainted != null) SchedulerBinding.instance.addPostFrameCallback((_) => onPainted!());
      final data = NoteData.of(node.node.value);
      final glyph = noteResizeButton(data.size).deflate(3);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          NoteCardView(data: data, hovered: node.hovered.value),
          if (node.hovered.value) Positioned.fromRect(rect: glyph, child: const NoteResizeGlyph()),
        ],
      );
    },
  );
}
