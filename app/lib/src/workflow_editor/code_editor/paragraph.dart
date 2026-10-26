import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import 'wrapping.dart';

/// Source positions belong to the unchanged logical line. Each visual row uses
/// the same projection for painting, hit tests, caret, selection and IME geometry.
class WrappedParagraph implements IParagraph {
  WrappedParagraph(this.span, this.style, double maxWidth, {this.tabSize = 4}) : text = span.toPlainText() {
    final measure = TextPainter(
      text: TextSpan(text: 'xｍ', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final boxes = measure.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 1),
    );
    charWidth = boxes.first.right - boxes.first.left;
    final full = measure.getBoxesForSelection(
      const TextSelection(baseOffset: 1, extentOffset: 2),
    );
    final fullWidth = full.first.right - full.first.left;
    pitch = measure.preferredLineHeight;
    measure.dispose();
    fullWidthColumns = fullWidth / charWidth;
    layoutWidth = maxWidth;
    projection = CodeLineWrapping.compute(
      text,
      columns: maxWidth.isFinite ? math.max(1, (maxWidth / charWidth).floor()) : -1,
      tabSize: tabSize,
      fullWidthColumns: fullWidth / charWidth,
    );
  }
  final TextSpan span;
  final TextStyle style;
  final String text;
  final int tabSize;
  late final CodeLineWrapping projection;
  late final double charWidth, pitch;
  TextPainter? _word;
  late final double fullWidthColumns, layoutWidth;
  final _rows = <int, _Row>{};
  _Row _row(int index) {
    final cached = _rows.remove(index);
    if (cached != null) {
      _rows[index] = cached;
      return cached;
    }
    final result = _buildRow(index);
    _rows[index] = result;
    while (_rows.length > 64) {
      _rows.remove(_rows.keys.first)?.painter.dispose();
    }
    return result;
  }

  _Row _buildRow(int index) {
    final start = projection.startOf(index), end = projection.breakOffsets[index];
    final toDisplay = List<int>.filled(end - start + 1, 0), toSource = <int>[0];
    final display = StringBuffer();
    double column = index == 0 ? 0 : projection.breakVisibleColumns[index - 1];
    var position = 0;
    for (var at = start; at < end; at++) {
      final code = text.codeUnitAt(at);
      final count = code == 9 ? (tabSize - column % tabSize).toInt() : 1;
      if (code == 9) {
        display.write(' ' * count);
      } else {
        display.writeCharCode(code);
      }
      for (var k = 1; k <= count; k++) {
        toSource.add(at - start + (k * 2 >= count ? 1 : 0));
      }
      position += count;
      toDisplay[at - start + 1] = position;
      if (code == 9) {
        column += count;
      } else if (CodeLineWrapping.isHighSurrogate(code)) {
        column++;
      } else {
        column += CodeLineWrapping.characterColumns(code, column, tabSize, fullWidthColumns);
      }
    }
    final content = display.toString();
    final styled = <InlineSpan>[];
    var sourceOffset = 0;
    void visit(TextSpan current, TextStyle inherited) {
      final effective = inherited.merge(current.style);
      final raw = current.text ?? '';
      final a = math.max(sourceOffset, start), b = math.min(sourceOffset + raw.length, end);
      if (a < b) {
        styled.add(
          TextSpan(
            text: content.substring(toDisplay[a - start], toDisplay[b - start]),
            style: effective,
          ),
        );
      }
      sourceOffset += raw.length;
      for (final child in current.children ?? const <InlineSpan>[]) {
        if (child is TextSpan) visit(child, effective);
      }
    }

    visit(span, style);
    final painter = TextPainter(
      text: TextSpan(children: styled, style: style),
      textDirection: TextDirection.ltr,
      strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
    )..layout();
    return _Row(
      painter,
      toDisplay,
      toSource,
      projection.indentOf(index) * charWidth,
    );
  }

  @override
  double get width => layoutWidth.isFinite ? layoutWidth : _row(0).painter.width;
  @override
  double get height => lineCount * pitch;
  @override
  double get preferredLineHeight => pitch;
  @override
  bool get trucated => false;
  @override
  int get length => text.length;
  @override
  int get lineCount => projection.rowCount;
  @override
  void draw(Canvas canvas, Offset offset) {
    final clip = canvas.getLocalClipBounds().shift(-offset);
    final first = (clip.top / pitch).floor().clamp(0, lineCount - 1);
    final last = (clip.bottom / pitch).ceil().clamp(0, lineCount - 1);
    for (var i = first; i <= last; i++) {
      _row(i).painter.paint(canvas, offset + Offset(_row(i).indent, i * pitch));
    }
  }

  @override
  TextPosition getPosition(Offset offset) {
    final index = (offset.dy / pitch).floor().clamp(0, lineCount - 1), r = _row(index);
    final pos = r.painter.getPositionForOffset(
      Offset(offset.dx - r.indent, offset.dy - index * pitch),
    );
    final at = r.toSource[pos.offset.clamp(0, r.toSource.length - 1)] + projection.startOf(index);
    return TextPosition(
      offset: at,
      affinity: at == projection.startOf(index) && index > 0
          ? TextAffinity.downstream
          : at == projection.breakOffsets[index] && index < lineCount - 1
          ? TextAffinity.upstream
          : pos.affinity,
    );
  }

  @override
  Offset getOffset(TextPosition pos) {
    final p = projection.toView(
          pos.offset,
          upstream: pos.affinity == TextAffinity.upstream,
        ),
        r = _row(p.row);
    final local = (pos.offset - projection.startOf(p.row)).clamp(
      0,
      r.toDisplay.length - 1,
    );
    final offset = r.painter.getOffsetForCaret(
      TextPosition(offset: r.toDisplay[local], affinity: pos.affinity),
      Rect.fromLTWH(0, 0, 1, pitch),
    );
    return offset + Offset(r.indent, p.row * pitch);
  }

  @override
  List<Rect> getRangeRects(TextRange range) {
    final result = <Rect>[];
    for (var i = 0; i < lineCount; i++) {
      final start = projection.startOf(i), end = projection.breakOffsets[i];
      final a = math.max(start, range.start), b = math.min(end, range.end);
      if (a >= b) continue;
      final r = _row(i);
      for (final box in r.painter.getBoxesForSelection(
        TextSelection(
          baseOffset: r.toDisplay[a - start],
          extentOffset: r.toDisplay[b - start],
        ),
        boxHeightStyle: ui.BoxHeightStyle.strut,
      )) {
        result.add(box.toRect().shift(Offset(r.indent, i * pitch)));
      }
    }
    return result;
  }

  @override
  TextRange getWord(Offset offset) {
    final word = _word ??= (TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout());
    return word.getWordBoundary(getPosition(offset));
  }

  @override
  TextRange getLineBoundary(TextPosition position) {
    final row = projection
        .toView(
          position.offset,
          upstream: position.affinity == TextAffinity.upstream,
        )
        .row;
    return TextRange(
      start: projection.startOf(row),
      end: projection.breakOffsets[row],
    );
  }

  @override
  InlineSpan? getSpanForPosition(TextPosition position) => span.getSpanForPosition(position);
  @override
  TextRange getRangeForSpan(InlineSpan target) {
    var at = 0;
    TextRange? found;
    void visit(InlineSpan current) {
      if (found != null) return;
      if (identical(current, target)) {
        found = TextRange(start: at, end: at + current.toPlainText().length);
        return;
      }
      if (current is TextSpan) {
        at += current.text?.length ?? 0;
        for (final child in current.children ?? const <InlineSpan>[]) {
          visit(child);
        }
      } else {
        at += current.toPlainText().length;
      }
    }

    visit(span);
    return found ?? TextRange.empty;
  }

  void dispose() {
    _word?.dispose();
    for (final r in _rows.values) {
      r.painter.dispose();
    }
  }
}

class _Row {
  _Row(this.painter, this.toDisplay, this.toSource, this.indent);
  final TextPainter painter;
  final List<int> toDisplay, toSource;
  final double indent;
}
