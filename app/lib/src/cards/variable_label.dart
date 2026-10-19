import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import 'card_kit.dart';
import '../design/widgets/widgets.dart';

// Variable selectors (nodes/_base/components/variable/utils.ts).
bool isSystemVar(List<String> v) => v.isNotEmpty && (v[0] == 'sys' || (v.length > 1 && v[1] == 'sys'));
bool isGlobalVar(List<String> v) => isSystemVar(v) && !(v.length > 1 && const ['query', 'files'].contains(v[1]));
bool isEnvVar(List<String> v) => v.isNotEmpty && v[0] == 'env';
bool isConversationVar(List<String> v) => v.isNotEmpty && v[0] == 'conversation';
bool isRagVariableVar(List<String> v) => v.isNotEmpty && v[0] == 'rag';

/// A variable a card refers to: its value selector ([path]), the node that provides it (null when unknown or not a
/// node's), [broken] (a reference to a deleted output, drawn like Dify's exception variables) and [short]
/// (`notShowFullPath`).
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
  static VarRef ofPath(List<String> path, BodyContext ctx, {bool short = false}) =>
      VarRef(node: isSystemVar(path) ? ctx.start : ctx.lookup(path.first), path: path, short: short);
}

/// The variants of VariableLabel (variable-label/*.tsx): [base] (variable-label.tsx; VariableLabelInSelect),
/// [inNode] (full width on the parameter background, no shadow), [inText] (18 px, inline in text) and [inEditor]
/// (like [inText], with hover and selected colours).
enum VarLabelStyle { base, inNode, inText, inEditor }

/// useVarName: the path after the node (after two segments for rag), or only the last segment; `sys.` in front of
/// system variables; `sys.query` and `sys.files` are "query" and "files" (VAR_SHOW_NAME_MAP).
String varName(List<String> v, {bool notShowFullPath = false}) {
  const showName = {'sys.query': 'query', 'sys.files': 'files'};
  final shown = showName[v.join('.')];
  if (shown != null) return shown;
  final full = v.skip(isRagVariableVar(v) ? 2 : 1).join('.');
  return '${isSystemVar(v) ? 'sys.' : ''}${notShowFullPath && v.isNotEmpty ? v.last : full}';
}

/// useVarColor.
Color varColor(List<String> v, {bool isExceptionVariable = false}) {
  if (isExceptionVariable) return DifyColors.textWarning;
  if (isEnvVar(v)) return DifyColors.utilColorsVioletViolet600;
  if (isConversationVar(v)) return DifyColors.utilColorsTealTeal700;
  if (isGlobalVar(v)) return DifyColors.utilColorsOrangeOrange600;
  return DifyColors.textAccent;
}

/// useVarIcon.
String varIcon(List<String> v) {
  if (isRagVariableVar(v)) return 'vender/pipeline/input-field';
  if (isEnvVar(v)) return 'vender/line/others/env';
  if (isConversationVar(v)) return 'vender/line/others/bubble-x';
  if (isGlobalVar(v)) return 'vender/line/others/global-variable';
  return 'vender/solid/development/variable-02';
}

/// Every (icon, colour) pair variable labels draw, for preloading.
Iterable<(String, Color)> get variableLabelIcons sync* {
  for (final v in const [
    ['n', 'x'],
    ['env', 'x'],
    ['conversation', 'x'],
    ['sys', 'user_id'],
    ['rag', 'x', 'y'],
  ]) {
    yield ('assets/dify_icons/${varIcon(v)}.svg', varColor(v));
    yield ('assets/dify_icons/${varIcon(v)}.svg', DifyColors.textWarning);
  }
  yield ('assets/remix_icons/more-line.svg', DifyColors.textSecondary);
  yield ('assets/dify_icons/vender/line/alertsAndFeedback/warning.svg', DifyColors.textWarning);
}

/// VariableIcon: the 14 px variable icon.
class VariableIcon extends StatelessWidget {
  const VariableIcon({super.key, required this.variables, this.color});
  final List<String> variables;
  final Color? color;

  @override
  Widget build(BuildContext context) => DifyIcon(varIcon(variables), size: 14, color: color);
}

/// VariableIconWithColor: [VariableIcon] in the variable's colour.
class VariableIconWithColor extends StatelessWidget {
  const VariableIconWithColor({super.key, required this.variables, this.isExceptionVariable = false});
  final List<String> variables;
  final bool isExceptionVariable;

  @override
  Widget build(BuildContext context) => VariableIcon(
    variables: variables,
    color: varColor(variables, isExceptionVariable: isExceptionVariable),
  );
}

/// VariableName: `truncate system-xs-medium`, with the name as its title.
class VariableName extends StatelessWidget {
  const VariableName({super.key, required this.variables, this.notShowFullPath = false, this.color});
  final List<String> variables;
  final bool notShowFullPath;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final name = varName(variables, notShowFullPath: notShowFullPath);
    return Tooltip(
      message: name,
      waitDuration: const Duration(milliseconds: 600),
      child: DifyText(name, DifyType.systemXsMedium, color: color ?? DifyColors.textPrimary),
    );
  }
}

/// VariableNodeLabel: the node icon, title (max 60 px) and "/"; nothing without a node type.
class VariableNodeLabel extends StatelessWidget {
  const VariableNodeLabel({super.key, this.nodeType, this.nodeTitle, this.gap = 1});
  final String? nodeType;
  final String? nodeTitle;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (nodeType == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        VarBlockIcon(type: nodeType!),
        if (nodeTitle != null) ...[
          SizedBox(width: gap),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 60),
            child: Tooltip(
              message: nodeTitle,
              waitDuration: const Duration(milliseconds: 600),
              child: DifyText(nodeTitle!, DifyType.systemXsMedium, color: DifyColors.textSecondary),
            ),
          ),
        ],
        SizedBox(width: gap),
        DifyText('/', DifyType.systemXsRegular, color: DifyColors.dividerDeep),
      ],
    );
  }
}

/// VariableLabel (variable-label/base/variable-label.tsx): `inline-flex h-6 items-center space-x-0.5 rounded-md
/// border-[0.5px] border-components-panel-border-subtle bg-components-badge-white-to-dark px-1.5 shadow-xs`, with the
/// node label, "…/" for a short path, the variable icon and name, the type, a warning for [errorMsg] and
/// [rightSlot]. The parameters are Dify's VariablePayload; [variant] picks the wrapper (InNode, InText, …).
class VariableLabel extends StatefulWidget {
  const VariableLabel({
    super.key,
    required this.variables,
    this.nodeType,
    this.nodeTitle,
    this.variableType,
    this.onTap,
    this.errorMsg,
    this.isExceptionVariable = false,
    this.notShowFullPath = false,
    this.rightSlot,
    this.variant = VarLabelStyle.base,
    this.isSelected = false,
    this.bare = false,
  });

  /// A label for [ref] (node title and type from the referenced node).
  factory VariableLabel.of(
    VarRef ref, {
    Key? key,
    VarLabelStyle variant = VarLabelStyle.base,
    String? variableType,
    Widget? rightSlot,
    bool bare = false,
  }) => VariableLabel(
    key: key,
    variables: ref.path,
    nodeType: ref.node?.type,
    nodeTitle: ref.node?.title,
    variableType: variableType,
    isExceptionVariable: ref.broken,
    notShowFullPath: ref.short,
    rightSlot: rightSlot,
    variant: variant,
    bare: bare,
  );

  final List<String> variables;
  final String? nodeType;
  final String? nodeTitle;
  final String? variableType;
  final VoidCallback? onTap;
  final String? errorMsg;
  final bool isExceptionVariable;
  final bool notShowFullPath;
  final Widget? rightSlot;
  final VarLabelStyle variant;

  /// [VarLabelStyle.inEditor]: selected.
  final bool isSelected;

  /// `border-none bg-transparent shadow-none` (the if-else condition).
  final bool bare;

  bool get _showsNode =>
      nodeType != null &&
      !(isEnvVar(variables) || isConversationVar(variables) || isGlobalVar(variables) || isRagVariableVar(variables));

  double get _height => variant == VarLabelStyle.inText || variant == VarLabelStyle.inEditor ? 18 : 24;
  double get _gap => variant == VarLabelStyle.base ? 2 : 1;
  double get _padding => variant == VarLabelStyle.base ? 6 : 4;
  double get _border => bare ? 0 : Css.border(variant == VarLabelStyle.inEditor && isSelected ? 1 : 0.5);

  /// es-toolkit capitalize: first letter upper case, the rest lower case.
  static String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

  /// The label's natural width (what `inline-flex` gives it): border, padding, parts and the gaps between them.
  double get intrinsicWidth {
    final parts = <double>[
      if (_showsNode) ...[
        12,
        if (nodeTitle != null) _textWidth(nodeTitle!, DifyType.systemXsMedium).clamp(0, 60),
        _textWidth('/', DifyType.systemXsRegular),
      ],
      if (notShowFullPath) ...[12, _textWidth('/', DifyType.systemXsRegular)],
      14,
      _textWidth(varName(variables, notShowFullPath: notShowFullPath), DifyType.systemXsMedium),
      if (variableType != null) _textWidth(capitalize(variableType!), DifyType.systemXsRegular),
      if (errorMsg != null) 12,
    ];
    return 2 * _border + 2 * _padding + parts.fold(0.0, (a, b) => a + b) + (parts.length - 1) * _gap;
  }

  /// Distance from the label's top to its baseline in a line of text: an `inline-flex` box takes the baseline of its
  /// first item, synthesised from the bottom of the (centred) icon.
  double get baseline {
    final first = _showsNode || notShowFullPath ? 12.0 : 14.0;
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
  State<VariableLabel> createState() => _VariableLabelState();
}

class _VariableLabelState extends State<VariableLabel> {
  bool _hovered = false;

  /// useVarBgColorInEditor: (hover border, hover background, selected border, selected background).
  (Color, Color, Color, Color) get _editorColors {
    final v = widget.variables;
    if (widget.errorMsg != null) {
      return (
        DifyColors.stateDestructiveActive,
        DifyColors.stateDestructiveHover,
        DifyColors.stateDestructiveSolid,
        DifyColors.stateDestructiveHover,
      );
    }
    if (isEnvVar(v)) {
      return (
        DifyColors.utilColorsVioletViolet100,
        DifyColors.utilColorsVioletViolet50,
        DifyColors.utilColorsVioletViolet600,
        DifyColors.utilColorsVioletViolet50,
      );
    }
    if (isConversationVar(v)) {
      return (
        DifyColors.utilColorsTealTeal100,
        DifyColors.utilColorsTealTeal50,
        DifyColors.utilColorsTealTeal600,
        DifyColors.utilColorsTealTeal50,
      );
    }
    return (
      // `hover:border-state-accent-alt` names no token, so Tailwind emits nothing: the border stays.
      DifyColors.componentsPanelBorderSubtle,
      DifyColors.stateAccentHover,
      DifyColors.stateAccentSolid,
      DifyColors.stateAccentHover,
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final color = varColor(w.variables, isExceptionVariable: w.isExceptionVariable);
    final gap = SizedBox(width: w._gap);
    final parts = <Widget>[
      if (w._showsNode) VariableNodeLabel(nodeType: w.nodeType, nodeTitle: w.nodeTitle, gap: w._gap),
      if (w.notShowFullPath) ...[
        RemixIcon('more-line', size: 12, color: DifyColors.textSecondary),
        DifyText('/', DifyType.systemXsRegular, color: DifyColors.dividerDeep),
      ],
      VariableIcon(variables: w.variables, color: color),
      Flexible(
        child: VariableName(variables: w.variables, notShowFullPath: w.notShowFullPath, color: color),
      ),
      if (w.variableType != null)
        DifyText(VariableLabel.capitalize(w.variableType!), DifyType.systemXsRegular, color: DifyColors.textTertiary),
      if (w.errorMsg != null)
        Tooltip(
          message: w.errorMsg,
          child: DifyIcon('vender/line/alertsAndFeedback/warning', size: 12, color: DifyColors.textWarning),
        ),
    ];
    final full = w.variant == VarLabelStyle.inNode;
    Widget row = Row(
      mainAxisSize: full && w.rightSlot == null ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (final (i, p) in parts.indexed) ...[if (i > 0) gap, p],
      ],
    );
    if (w.rightSlot != null) {
      row = Row(
        mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Flexible(fit: full ? FlexFit.tight : FlexFit.loose, child: row),
          gap,
          w.rightSlot!,
        ],
      );
    }
    var background = full ? DifyColors.workflowBlockParmaBg : DifyColors.componentsBadgeWhiteToDark;
    var border = DifyColors.componentsPanelBorderSubtle;
    if (w.variant == VarLabelStyle.inEditor) {
      final (hb, hbg, sb, sbg) = _editorColors;
      if (w.isSelected) {
        border = sb;
        background = sbg;
      } else if (_hovered) {
        border = hb;
        background = hbg;
      }
    }
    Widget label = Container(
      key: w.isExceptionVariable ? const Key('exception-variable') : null,
      height: w._height,
      padding: EdgeInsets.symmetric(horizontal: w._padding),
      decoration: w.bare
          ? null
          : BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(w.variant == VarLabelStyle.base || full ? DifyRadius.md : 5),
              border: Border.all(color: border, width: w._border),
              boxShadow: full ? null : DifyShadows.xs,
            ),
      child: row,
    );
    if (w.variant == VarLabelStyle.inEditor) {
      label = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: label,
      );
    }
    if (w.onTap != null) label = GestureDetector(onTap: w.onTap, child: label);
    return label;
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
    this._color,
    this.breakAll = true,
    this.truncate = false,
  });
  final String text;
  final BodyContext ctx;
  final Color? _color;
  Color get color => _color ?? DifyColors.textTertiary;
  final bool breakAll;
  final bool truncate;

  static final _pattern = RegExp(r'\{\{#([^#]*)#\}\}');
  static TextStyle get _style => DifyType.systemXsRegular.style; // text-xs

  /// Text pieces lie 3 px above where the line puts them; the chips don't move.
  static const textLift = 3.0;

  late final List<(String?, VariableLabel?)> _parts = () {
    String spread(String t) => breakAll ? t.runes.map(String.fromCharCode).join('​') : t;
    final out = <(String?, VariableLabel?)>[];
    var at = 0;
    for (final m in _pattern.allMatches(text)) {
      if (m.start > at) out.add((spread(text.substring(at, m.start)), null));
      final path = m.group(1)!.split('.');
      out.add((
        null,
        VariableLabel.of(VarRef.ofPath(path, ctx, short: path.length > 2), variant: VarLabelStyle.inText),
      ));
      at = m.end;
    }
    if (at < text.length) out.add((spread(text.substring(at)), null));
    return out;
  }();

  /// A chip's slot in the line: from its top to the line's bottom in Chrome (the text's rounded descent and leading
  /// can reach lower than the chip).
  static double _slot(VariableLabel l) => max(18, l.baseline + Css.textLine(12, 16).below);

  TextStyle get _base => _style.copyWith(fontFamily: cardFontFamily, color: color);

  List<PlaceholderDimensions> _dims(double width) => [
    for (final (_, l) in _parts)
      if (l != null)
        PlaceholderDimensions(
          size: Size(min(l.intrinsicWidth, width), _slot(l)),
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
    // The paragraph's own style is [_base], as in [height] (not the ambient text style, whose font size and leading
    // would size a line holding only chips).
    Widget para(TextSpan s) => DefaultTextStyle(
      style: _base,
      child: Text.rich(
        s,
        maxLines: truncate ? 1 : null,
        overflow: truncate ? TextOverflow.ellipsis : TextOverflow.clip,
        textHeightBehavior: const TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even),
      ),
    );
    return Stack(
      children: [
        para(
          _span(
            (l) => SizedBox(
              width: l.intrinsicWidth,
              height: _slot(l),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(height: 18, child: l),
              ),
            ),
            Colors.transparent,
          ),
        ),
        Positioned.fill(
          top: -textLift,
          bottom: textLift,
          child: para(_span((l) => SizedBox(width: l.intrinsicWidth, height: _slot(l)), color)),
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
