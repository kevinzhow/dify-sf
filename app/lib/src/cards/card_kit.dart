import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';

/// What a card body needs besides its own node: other nodes, for labels of the variables it references.
class BodyContext {
  const BodyContext(this.node, this.lookup, {this.start, this.viewOrigin = Offset.zero});
  final Node node;
  final Node? Function(String id) lookup;

  /// The workflow's Start node (system variables are shown under it).
  final Node? start;

  /// Where the canvas origin was on screen when the view last came to rest (React Flow's viewport x, y), for
  /// content tied to the viewport: the dot background inside containers.
  final Offset viewOrigin;

  Value? operator [](String key) => node.config[key];
}

/// The font cards render with (the app theme's family); measurement outside the widget tree needs it explicitly.
String? cardFontFamily;

/// A Dify text style in a colour (uppercase styles are applied by [DifyText]).
TextStyle difyStyle(DifyTextStyle s, Color color) => s.style.copyWith(color: color, fontFamily: cardFontFamily);

/// The height of [text] in [style] laid out at [width] (description, answer text).
double textHeight(String text, TextStyle style, double width, {int? maxLines}) {
  if (text.isEmpty) return 0;
  final p = TextPainter(
    text: TextSpan(
      text: text,
      style: style.copyWith(fontFamily: cardFontFamily),
    ),
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
  )..layout(maxWidth: width);
  final h = p.height;
  p.dispose();
  return h;
}

/// Text in a Dify typography utility (applies `uppercase`).
class DifyText extends StatelessWidget {
  const DifyText(
    this.text,
    this.style, {
    super.key,
    this.color = DifyColors.textPrimary,
    this.align,
    this.maxLines = 1,
  });
  final String text;
  final DifyTextStyle style;
  final Color color;
  final TextAlign? align;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Text(
    style.uppercase ? text.toUpperCase() : text,
    style: difyStyle(style, color),
    textAlign: align,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
  );
}

/// A row on the card: `flex h-6 items-center rounded-md bg-workflow-block-parma-bg px-1`.
class ParamRow extends StatelessWidget {
  const ParamRow({super.key, required this.child, this.height = 24});
  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      color: DifyColors.workflowBlockParmaBg,
      borderRadius: BorderRadius.circular(DifyRadius.md),
    ),
    child: child,
  );
}

/// The small node icon in variable labels (VarBlockIcon): the type glyph, no tile, in text-secondary.
class VarBlockIcon extends StatelessWidget {
  const VarBlockIcon({super.key, required this.type, this.size = 12});
  final String type;
  final double size;

  @override
  Widget build(BuildContext context) => DifyIcon(varBlockGlyph(type), size: size, color: DifyColors.textSecondary);
}

/// A reference to a variable as the card shows it (variable-label/base/variable-label.tsx): the value selector
/// ([path]), the node whose icon and title are shown, and whether it is drawn in text-warning ([broken]: a reference
/// to a deleted output, or an error output of a node with error handling). [short]: `notShowFullPath`, only the last
/// segment after "…/".
class VarRef {
  const VarRef({this.node, required this.path, this.broken = false, this.short = false});
  final Node? node;
  final List<String> path;
  final bool broken;
  final bool short;

  VarRef copyWith({bool? broken, bool? short}) =>
      VarRef(node: node, path: path, broken: broken ?? this.broken, short: short ?? this.short);

  /// Resolves a value selector as the document stores it (a reference, a broken reference, or a plain list for
  /// sys/env/conversation variables).
  static VarRef? of(Value? v, BodyContext ctx) {
    switch (v) {
      case VRef(:final ref):
        return VarRef(node: ctx.lookup(ref.node), path: [ref.node, ref.output]);
      case VBroken(:final ref):
        return VarRef(path: [ref.node, ref.output], broken: true);
      case VList(:final items) when items.isNotEmpty:
        final parts = [
          for (final i in items)
            if (i is VString) i.value,
        ];
        return parts.length < 2 ? null : ofPath(parts, ctx);
      default:
        return null;
    }
  }

  /// A selector as written in text (`{{#node.var#}}` split at the dots). System variables show under Start.
  static VarRef ofPath(List<String> path, BodyContext ctx, {bool short = false}) {
    final system = path.first == 'sys' || (path.length > 1 && path[1] == 'sys');
    return VarRef(node: system ? ctx.start : ctx.lookup(path.first), path: path, short: short);
  }

  // variable/utils.ts
  bool get system => path.first == 'sys' || (path.length > 1 && path[1] == 'sys');
  bool get global => system && !(path.length > 1 && const ['query', 'files'].contains(path[1]));
  bool get env => path.first == 'env';
  bool get conversation => path.first == 'conversation';
  bool get rag => path.first == 'rag';

  VarKind get kind => rag
      ? VarKind.rag
      : env
      ? VarKind.environment
      : conversation
      ? VarKind.conversation
      : global
      ? VarKind.system
      : VarKind.node;

  /// The node label (icon, title, "/") is shown for node variables of a node that exists.
  bool get showsNode => node != null && !(env || conversation || global || rag);

  /// useVarName: the path after the node (after two segments for rag), or only the last segment when [short];
  /// `sys.` in front for system variables; `sys.query` and `sys.files` are "query" and "files".
  String get name {
    const showName = {'sys.query': 'query', 'sys.files': 'files'};
    final shown = showName[path.join('.')];
    if (shown != null) return shown;
    final full = path.skip(rag ? 2 : 1).join('.');
    return '${system ? 'sys.' : ''}${short ? path.last : full}';
  }
}

enum VarKind { node, system, environment, conversation, rag }

/// Variable colour by kind (variable-label hooks: useVarColor).
Color varColor(VarKind k) => switch (k) {
  VarKind.environment => DifyColors.utilColorsVioletViolet600,
  VarKind.conversation => DifyColors.utilColorsTealTeal700,
  VarKind.system => DifyColors.utilColorsOrangeOrange600,
  VarKind.node || VarKind.rag => DifyColors.textAccent,
};

/// Variable icon by kind (variable-label hooks: useVarIcon).
String varIcon(VarKind k) => switch (k) {
  VarKind.environment => 'vender/line/others/env',
  VarKind.conversation => 'vender/line/others/bubble-x',
  VarKind.system => 'vender/line/others/global-variable',
  VarKind.rag => 'vender/pipeline/input-field',
  VarKind.node => 'vender/solid/development/variable-02',
};

/// The variants of VariableLabel: [base] (variable-label.tsx itself), [inNode] (VariableLabelInNode: full width on
/// the parameter background, no shadow) and [inText] (VariableLabelInText: 18 px, inline in text).
enum VarLabelStyle { base, inNode, inText }

/// VariableLabel (variable-label/base/variable-label.tsx): `inline-flex h-6 items-center space-x-0.5 rounded-md
/// border-[0.5px] border-components-panel-border-subtle bg-components-badge-white-to-dark px-1.5 shadow-xs`, with
/// the node icon + title + "/", "…" + "/" for a short path, the variable icon + name, and the type.
class VariableLabel extends StatelessWidget {
  const VariableLabel({
    super.key,
    required this.ref,
    this.inNode = true,
    this.type,
    this.variant,
    this.bare = false,
    this.rightSlot,
  });
  final VarRef ref;
  final bool inNode;
  final String? type;

  /// `border-none bg-transparent shadow-none` (the if-else condition).
  final bool bare;

  /// Pushed to the right end (`ml-auto`), e.g. the assigner's operation badge.
  final Widget? rightSlot;

  /// Overrides [inNode].
  final VarLabelStyle? variant;

  VarLabelStyle get style => variant ?? (inNode ? VarLabelStyle.inNode : VarLabelStyle.inText);

  double get _height => style == VarLabelStyle.inText ? 18 : 24;
  double get _gap => style == VarLabelStyle.base ? 2 : 1;
  double get _padding => style == VarLabelStyle.base ? 6 : 4;

  /// es-toolkit capitalize: first letter upper case, the rest lower case.
  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

  /// The parts in order: (widget, width when measured; null for the name, which takes the rest).
  List<Widget> _parts(Color color) => [
    if (ref.showsNode) ...[
      VarBlockIcon(type: ref.node!.type),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 60),
        child: DifyText(ref.node!.title, DifyType.systemXsMedium, color: DifyColors.textSecondary),
      ),
      const DifyText('/', DifyType.systemXsRegular, color: DifyColors.dividerDeep),
    ],
    if (ref.short) ...[
      const RemixIcon('more-line', size: 12, color: DifyColors.textSecondary),
      const DifyText('/', DifyType.systemXsRegular, color: DifyColors.dividerDeep),
    ],
    DifyIcon(varIcon(ref.kind), size: 14, color: color),
    Flexible(child: DifyText(ref.name, DifyType.systemXsMedium, color: color)),
    if (type != null) DifyText(_capitalize(type!), DifyType.systemXsRegular, color: DifyColors.textTertiary),
  ];

  /// The label's natural width (what `inline-flex` gives it): border, padding, parts and the gaps between them.
  double get intrinsicWidth {
    final parts = <double>[
      if (ref.showsNode) ...[
        12,
        _textWidth(ref.node!.title, DifyType.systemXsMedium).clamp(0, 60),
        _textWidth('/', DifyType.systemXsRegular),
      ],
      if (ref.short) ...[12, _textWidth('/', DifyType.systemXsRegular)],
      14,
      _textWidth(ref.name, DifyType.systemXsMedium),
      if (type != null) _textWidth(_capitalize(type!), DifyType.systemXsRegular),
    ];
    return (bare ? 0 : 1) + 2 * _padding + parts.fold(0.0, (a, b) => a + b) + (parts.length - 1) * _gap;
  }

  /// Distance from the label's top to its baseline in a line of text: an `inline-flex` box takes the baseline of its
  /// first item, synthesised from the bottom of the (centred) icon.
  double get baseline {
    final first = ref.showsNode || ref.short ? 12.0 : 14.0;
    return (_height + first) / 2;
  }

  static double _textWidth(String s, DifyTextStyle t) {
    final p = TextPainter(
      text: TextSpan(text: s, style: difyStyle(t, DifyColors.textPrimary)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = p.width;
    p.dispose();
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final color = ref.broken ? DifyColors.textWarning : varColor(ref.kind);
    final parts = _parts(color);
    final full = style == VarLabelStyle.inNode;
    Widget row = Row(
      mainAxisSize: full && rightSlot == null ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (final (i, p) in parts.indexed) ...[if (i > 0) SizedBox(width: _gap), p],
      ],
    );
    if (rightSlot != null) {
      row = Row(
        mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Flexible(fit: full ? FlexFit.tight : FlexFit.loose, child: row),
          SizedBox(width: _gap),
          rightSlot!,
        ],
      );
    }
    return Container(
      height: _height,
      padding: EdgeInsets.symmetric(horizontal: _padding),
      decoration: bare
          ? null
          : BoxDecoration(
              color: full ? DifyColors.workflowBlockParmaBg : DifyColors.componentsBadgeWhiteToDark,
              borderRadius: BorderRadius.circular(style == VarLabelStyle.inText ? 5 : DifyRadius.md),
              border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: 0.5),
              boxShadow: full ? null : DifyShadows.xs,
            ),
      child: row,
    );
  }
}

/// Text with `{{#node.var#}}` references as inline variable labels (readonly-input-with-select-var.tsx: `text-xs`,
/// text pieces `relative -top-0.75 leading-4`, VariableLabelInText chips, "…" for paths over two segments), with a
/// height that can be computed without building it. [breakAll]: CSS `break-all`, a line may break between any two
/// characters; [truncate]: one line cut with an ellipsis.
class InlineVarText {
  InlineVarText(
    this.text,
    this.ctx, {
    this.color = DifyColors.textTertiary,
    this.breakAll = true,
    this.truncate = false,
  });
  final String text;
  final BodyContext ctx;
  final Color color;
  final bool breakAll;
  final bool truncate;

  static final _pattern = RegExp(r'\{\{#([^#]*)#\}\}');
  static const _style = TextStyle(fontSize: 12, height: 16 / 12, leadingDistribution: TextLeadingDistribution.even);

  /// Text pieces lie 3 px above where the line puts them; the chips don't move.
  static const textLift = 3.0;

  late final List<(String?, VariableLabel?)> _parts = () {
    String spread(String t) => breakAll ? t.runes.map(String.fromCharCode).join('​') : t;
    final out = <(String?, VariableLabel?)>[];
    var at = 0;
    for (final m in _pattern.allMatches(text)) {
      if (m.start > at) out.add((spread(text.substring(at, m.start)), null));
      final path = m.group(1)!.split('.');
      out.add((null, VariableLabel(ref: VarRef.ofPath(path, ctx, short: path.length > 2), inNode: false)));
      at = m.end;
    }
    if (at < text.length) out.add((spread(text.substring(at)), null));
    return out;
  }();

  TextStyle get _base => _style.copyWith(fontFamily: cardFontFamily, color: color);

  List<PlaceholderDimensions> _dims(double width) => [
    for (final (_, l) in _parts)
      if (l != null)
        PlaceholderDimensions(
          size: Size(min(l.intrinsicWidth, width), 18),
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          baselineOffset: l.baseline,
        ),
  ];

  /// The paragraph with the chips as [chip] placeholders and the text in [textColor].
  TextSpan _span(Widget Function(VariableLabel) chip, Color textColor) => TextSpan(
    style: _base.copyWith(color: textColor),
    children: [
      for (final (t, l) in _parts)
        if (t != null)
          TextSpan(text: t)
        else
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _Baseline(l!.baseline, chip(l)),
          ),
    ],
  );

  double height(double width) {
    if (text.isEmpty) return 0;
    final p = TextPainter(
      text: _span((_) => const SizedBox.shrink(), color),
      textDirection: TextDirection.ltr,
      maxLines: truncate ? 1 : null,
      ellipsis: truncate ? '…' : null,
    );
    p.setPlaceholderDimensions(_dims(width));
    p.layout(maxWidth: width);
    final h = p.height;
    p.dispose();
    return h;
  }

  /// Two copies of the same paragraph: the chips (text transparent), and the text lifted by [textLift] (chips
  /// left out).
  Widget build() {
    if (text.isEmpty) return const SizedBox.shrink();
    Widget para(TextSpan s) => LayoutBuilder(
      builder: (context, c) => Text.rich(
        s,
        maxLines: truncate ? 1 : null,
        overflow: truncate ? TextOverflow.ellipsis : TextOverflow.clip,
        textHeightBehavior: const TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even),
      ),
    );
    return Stack(
      children: [
        para(_span((l) => SizedBox(width: l.intrinsicWidth, height: 18, child: l), const Color(0x00000000))),
        Positioned.fill(
          top: -textLift,
          bottom: textLift,
          child: para(_span((l) => SizedBox(width: l.intrinsicWidth, height: 18), color)),
        ),
      ],
    );
  }
}

/// Reports [baseline] as its child's baseline (an `inline-flex` label in a line of text).
class _Baseline extends SingleChildRenderObjectWidget {
  const _Baseline(this.baseline, Widget child) : super(child: child);
  final double baseline;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBaseline(baseline);

  @override
  void updateRenderObject(BuildContext context, _RenderBaseline r) => r.baseline = baseline;
}

class _RenderBaseline extends RenderProxyBox {
  _RenderBaseline(this._baseline);
  double _baseline;
  set baseline(double v) {
    if (v == _baseline) return;
    _baseline = v;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) => _baseline;
}
