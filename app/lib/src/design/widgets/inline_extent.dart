import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../css_metrics.dart';

/// CSS's intrinsic block height for editable text containing `vertical-align:middle` inline boxes.
/// SkParagraph rounds line advances to whole logical pixels; Blink retains 1/64 px values.
/// Reserve the CSS extent so following form controls do not accumulate the paragraph's rounding error.
/// Text, selection, caret and inline widgets continue to be drawn and edited by the existing RenderEditable.
class CssInlineExtent extends SingleChildRenderObjectWidget {
  const CssInlineExtent({
    super.key,
    required this.fontSize,
    required this.lineHeight,
    required this.inlineOffsets,
    required super.child,
  });

  final double fontSize, lineHeight;
  final List<int> inlineOffsets;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderCssInlineExtent(fontSize, lineHeight, inlineOffsets);

  @override
  void updateRenderObject(BuildContext context, covariant RenderCssInlineExtent renderObject) =>
      renderObject.update(fontSize, lineHeight, inlineOffsets);
}

class RenderCssInlineExtent extends RenderProxyBox {
  RenderCssInlineExtent(this.fontSize, this.lineHeight, this.inlineOffsets);
  double fontSize, lineHeight;
  List<int> inlineOffsets;

  void update(double font, double height, List<int> offsets) {
    fontSize = font;
    lineHeight = height;
    inlineOffsets = offsets;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (inlineOffsets.isEmpty) return;
    RenderEditable? editable;
    void find(RenderObject node) {
      if (node is RenderEditable) {
        editable = node;
      } else if (editable == null) {
        node.visitChildren(find);
      }
    }

    child!.visitChildren(find);
    final field = editable;
    if (field == null) return;
    final text = field.text?.toPlainText() ?? '';
    final lines = <TextRange, ({double above, double below})>{};
    final strut = Css.textLine(fontSize, lineHeight);
    var offset = 0;
    while (true) {
      final range = field.getLineAtOffset(TextPosition(offset: offset));
      lines.putIfAbsent(range, () => strut);
      if (offset == text.length) break;
      offset = range.end > offset ? range.end : offset + 1;
    }
    final boxes = <RenderBox>[];
    for (RenderBox? box = field.firstChild; box != null; box = field.childAfter(box)) {
      boxes.add(box);
    }
    if (boxes.length != inlineOffsets.length) return;
    // Blink's LayoutUnit quantizes font-derived x-height to 1/64 CSS px.
    final halfXHeight = (fontSize * 0.536 / 2 * 64).round() / 64;
    for (var i = 0; i < boxes.length; i++) {
      // CanvasKit can assign the leading edge at a soft wrap to the previous
      // line. The trailing edge with upstream affinity identifies the box's line.
      final range = field.getLineAtOffset(TextPosition(offset: inlineOffsets[i] + 1, affinity: TextAffinity.upstream));
      final current = lines[range] ?? strut;
      final half = boxes[i].getDryLayout(boxes[i].constraints).height / 2;
      lines[range] = (
        above: math.max(current.above, half + halfXHeight),
        below: math.max(current.below, half - halfXHeight),
      );
    }
    final cssHeight = lines.values.fold<double>(0, (sum, line) => sum + line.above + line.below);
    size = constraints.constrain(Size(size.width, math.max(0, cssHeight)));
  }
}
