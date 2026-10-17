import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../design/dify_tokens.g.dart';
import '../card_kit.dart';
import '../node_body.dart';

/// Text with `{{#node.var#}}` references shown as inline variable chips (readonly-input-with-select-var.tsx), with a
/// height that can be computed without laying the widget out: chips are placeholders of measured width.
class InlineVarText {
  InlineVarText(this.text, this.ctx);
  final String text;
  final BodyContext ctx;

  static final _pattern = RegExp(r'\{\{#([^#]+)#\}\}');
  static const style = TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary);
  static const chipHeight = 18.0;

  List<(String?, VarRef?)> get _parts {
    final out = <(String?, VarRef?)>[];
    var at = 0;
    for (final m in _pattern.allMatches(text)) {
      if (m.start > at) out.add((text.substring(at, m.start), null));
      final path = m.group(1)!.split('.');
      final ref = VarRef.of(VList([for (final p in path) VString(p)]), ctx);
      out.add((null, ref ?? VarRef(name: path.last)));
      at = m.end;
    }
    if (at < text.length) out.add((text.substring(at), null));
    return out;
  }

  /// A chip's width: icon 12 + title (max 60) + "/" + icon 14 + name, padding 4 + 4.
  double _chipWidth(VarRef r) {
    double w(String s, DifyTextStyle t) => (TextPainter(
      text: TextSpan(
        text: s,
        style: t.style.copyWith(fontFamily: cardFontFamily),
      ),
      textDirection: TextDirection.ltr,
    )..layout()).width;
    var width = 8 + 14 + 1 + w(r.name, DifyType.systemXsMedium);
    if (r.node != null)
      width += 12 + 1 + w(r.node!.title, DifyType.systemXsMedium).clamp(0, 60) + w('/', DifyType.systemXsRegular);
    return width;
  }

  InlineSpan span() => TextSpan(
    style: style.copyWith(fontFamily: cardFontFamily),
    children: [
      for (final (t, r) in _parts)
        if (t != null)
          TextSpan(text: t)
        else
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              width: _chipWidth(r!),
              height: chipHeight,
              child: VariableLabel(ref: r, inNode: false),
            ),
          ),
    ],
  );

  double height(double width) {
    if (text.isEmpty) return 0;
    final parts = _parts;
    final p = TextPainter(
      text: TextSpan(
        style: style.copyWith(fontFamily: cardFontFamily),
        children: [
          for (final (t, r) in parts)
            if (t != null) TextSpan(text: t) else const WidgetSpan(child: SizedBox.shrink()),
        ],
      ),
      textDirection: TextDirection.ltr,
    );
    p.setPlaceholderDimensions([
      for (final (t, r) in parts)
        if (t == null)
          PlaceholderDimensions(size: Size(_chipWidth(r!), chipHeight), alignment: PlaceholderAlignment.middle),
    ]);
    p.layout(maxWidth: width);
    final h = p.height;
    p.dispose();
    return h;
  }
}

/// Answer (nodes/answer/node.tsx): an InfoPanel titled "Answer" with the answer text and its variable chips.
class AnswerBody extends NodeBody {
  const AnswerBody();

  // Card 240 - border 2 - px-3 24 - InfoPanel px-1.25 10.
  static const contentWidth = 204.0;

  String _answer(BodyContext ctx) => ctx['answer'] is VString ? (ctx['answer']! as VString).value : '';

  @override
  double height(BodyContext ctx) {
    final content = InlineVarText(_answer(ctx), ctx).height(contentWidth);
    // mb-1 + py-1 + InfoPanel (py-0.75 x 2 + title 12 + gap-y-0.5 + content).
    return 4 + 4 + 3 + 12 + 2 + content + 3 + 4;
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final text = InlineVarText(_answer(ctx), ctx);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: DifyColors.workflowBlockParmaBg,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DifyText('Answer', DifyType.system2xsSemiboldUppercase, color: DifyColors.textSecondary),
            const SizedBox(height: 2),
            if (_answer(ctx).isNotEmpty) Text.rich(text.span()),
          ],
        ),
      ),
    );
  }
}
