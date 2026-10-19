/// The line chart Dify's Overview draws with ECharts (`ReactECharts` over [ChartOptions]), painted directly: ECharts'
/// look comes from its own layout rules (nice y ticks ending at a fixed maximum, the category axis's automatic label
/// interval and `hideOverlap`, `containLabel`'s grid, `emptyCircle` symbols, the item tooltip above a point), so they
/// are ported here rather than approximated through a chart package (see the Overview's notes in docs).
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'app_chart_utils.dart';

/// ECharts' axis label font size and the gap between a label and its axis (`axisLabel.margin`).
const _labelFontSize = 12.0, _labelMargin = 8.0;

/// zrender's text line height for a 12 px font (the width of '国'), which ECharts lays labels out with.
const _labelBoxHeight = 12.0;

/// `symbolSize: 4`; line series `lineStyle.width: 2`.
const _symbolSize = 4.0, _lineWidth = 2.0;

/// ECharts `numberUtil.nice(val, round = true)`.
double niceNumber(double val) {
  if (val <= 0 || !val.isFinite) return 1;
  final exponent = (math.log(val) / math.ln10).floor();
  final exp10 = math.pow(10, exponent).toDouble();
  final f = val / exp10;
  final nf = f < 1.5
      ? 1
      : f < 2.5
      ? 2
      : f < 4
      ? 3
      : f < 7
      ? 5
      : 10;
  return double.parse((nf * exp10).toStringAsPrecision(12));
}

/// The value axis's ticks for `[0, max]` with ECharts' defaults (`splitNumber: 5`, the fixed max added as a last
/// tick when it is not a multiple of the interval). A zero extent becomes `[0, 1]` as in ECharts.
List<double> valueAxisTicks(double max) {
  final top = max <= 0 || !max.isFinite ? 1.0 : max;
  final interval = niceNumber(top / 5);
  final digits = math.max(0, -(math.log(interval) / math.ln10).floor() + 2);
  double round(double v) => double.parse(v.toStringAsFixed(digits));
  final ticks = <double>[];
  final last = round((top / interval).floor() * interval);
  for (var t = 0.0; t <= last + interval / 1e6; t = round(t + interval)) {
    ticks.add(t);
    if (ticks.length > 3000) break;
  }
  if (top > (ticks.isEmpty ? 0 : ticks.last)) ticks.add(top);
  return ticks;
}

/// The width ECharts measures for a number label (`containLabel` makes room for the widest y label): Dify sets no
/// font, so the canvas measures ECharts' default `12px sans-serif`, which browsers resolve to Helvetica / Arial (or a
/// metric-compatible font such as Liberation Sans): digits 0.556 em, `,` and `.` 0.278 em, `-` 0.333 em. Null for other
/// text (measured with the chart's own font).
double? echartsNumberWidth(String text) {
  var em = 0.0;
  for (final c in text.codeUnits) {
    em += switch (c) {
      >= 0x30 && <= 0x39 => 0.556,
      0x2C || 0x2E || 0x20 => 0.278,
      0x2D => 0.333,
      _ => double.nan,
    };
  }
  return em.isNaN ? null : em * _labelFontSize;
}

/// LineView's area default `opacity: 0.7` (areaStyle sets none in Dify), applied to the gradient's colours.
Color _areaOpacity(Color c) => c.withValues(alpha: c.a * 0.7);

/// zrender's `subPixelOptimize` for a 1 px line (`positiveOrNegative: true`): the position doubled and rounded, then
/// moved to the nearest half pixel at or after it, so the line covers whole pixels.
double echartsCrisp(double v) {
  final d = (v * 2).roundToDouble();
  return d % 2 != 0 ? d / 2 : (d + 1) / 2;
}

/// The value axis's label of [v] (ECharts' `addCommas` on the rounded value).
String valueAxisLabel(double v) => toLocaleString(v, maxFraction: 10);

/// One laid out x axis label.
class ChartXLabel {
  ChartXLabel(this.index, this.text, this.width, this.x);
  final int index;
  final String text;
  final double width;
  final double x;
  bool visible = true;

  double get left => x - width / 2;
  double get right => x + width / 2;
}

/// Where everything of a chart goes for a given size (ECharts' grid with `containLabel`, its tick and label rules).
class ChartLayout {
  ChartLayout._(this.plot, this.yTicks, this.yLabels, this.xs, this.xLabels, this.values, this.yTop, this.symbols);

  factory ChartLayout.of(ChartOptions o, Size size, TextStyle labelStyle) {
    final rows = o.source;
    final n = rows.length;
    final values = [for (final r in rows) chartRowValue(r, o.yField)];
    final dataMax = values.whereType<double>().fold(0.0, math.max);
    final ticks = valueAxisTicks(o.yMax ?? dataMax);
    final yTop = ticks.last;
    double measure(String s) => _painter(s, labelStyle).width;
    final yLabels = [for (final t in ticks) valueAxisLabel(t)];
    final yLabelWidth = yLabels.map((t) => echartsNumberWidth(t) ?? measure(t)).fold(0.0, math.max);
    final texts = [for (final r in rows) o.formatXLabel('${r['date'] ?? ''}')];
    final widths = texts.map(measure).toList();
    final g = o.grid;
    final top = g.top;
    final bottom = size.height - g.bottom - _labelBoxHeight - _labelMargin;
    // containLabel makes room for the y labels only: the plot runs to the right edge, and the first and last date
    // labels, centred on the plot's edges, overflow it and are clipped by the chart's box (as in Dify).
    final left = g.left + yLabelWidth + _labelMargin, right = size.width - g.right;
    final plotWidth = math.max(1.0, right - left);
    final xs = [for (var i = 0; i < n; i++) n == 1 ? left + plotWidth / 2 : left + i * plotWidth / (n - 1)];
    final interval = _categoryInterval(widths, n < 2 ? 0 : plotWidth / (n - 1));
    final labels = _viewLabels(texts, widths, xs, interval);
    _hideOverlap(labels);
    final plot = Rect.fromLTRB(left, top, math.max(left + 1, right), math.max(top + 1, bottom));
    // showAllSymbol 'auto': every symbol when there is room for one and a half of them per category, else only the
    // ones on the label interval.
    final step = math.max(1, (n / 5).round());
    var showAll = true;
    for (var i = 0; i < n; i += step) {
      if (_symbolSize * 1.5 > plot.width / n) showAll = false;
    }
    final onInterval = {for (final l in labels) l.index};
    final symbols = [for (var i = 0; i < n; i++) values[i] != null && (showAll || onInterval.contains(i))];
    return ChartLayout._(plot, ticks, yLabels, xs, labels, values, yTop, symbols);
  }

  final Rect plot;
  final List<double> yTicks;
  final List<String> yLabels;
  final List<double> xs;
  final List<ChartXLabel> xLabels;
  final List<double?> values;
  final double yTop;

  /// Whether the point of each row shows its symbol (and can be hovered).
  final List<bool> symbols;

  double yOf(double v) => plot.bottom - (v / yTop) * plot.height;

  Offset? pointOf(int i) => switch (values[i]) {
    final v? => Offset(xs[i], yOf(v)),
    null => null,
  };

  /// The category axis's automatic label interval (`calculateCategoryInterval`): label boxes are taken 1.3 times
  /// their size, at least 7 px.
  static int _categoryInterval(List<double> widths, double unit) {
    if (widths.length < 2 || unit <= 0) return 0;
    final step = widths.length > 40 ? math.max(1, widths.length ~/ 40) : 1;
    var maxW = 0.0;
    for (var i = 0; i < widths.length; i += step) {
      maxW = math.max(maxW, math.max(widths[i] * 1.3, 7));
    }
    return math.max(0, (maxW / unit).floor());
  }

  /// The labels on the interval, plus the last one (axis extent labels are always considered).
  static List<ChartXLabel> _viewLabels(List<String> texts, List<double> widths, List<double> xs, int interval) {
    final out = <ChartXLabel>[];
    final n = texts.length;
    for (var i = 0; i < n; i += interval + 1) {
      out.add(ChartXLabel(i, texts[i], widths[i], xs[i]));
    }
    if (n > 0 && out.last.index != n - 1) out.add(ChartXLabel(n - 1, texts[n - 1], widths[n - 1], xs[n - 1]));
    return out;
  }

  /// `hideOverlap`: a label overlapping one already shown is hidden; the off-interval extent label comes last.
  static void _hideOverlap(List<ChartXLabel> labels) {
    final shown = <ChartXLabel>[];
    for (final l in labels) {
      l.visible = !shown.any((s) => l.left < s.right && s.left < l.right);
      if (l.visible) shown.add(l);
    }
  }
}

TextPainter _painter(String text, TextStyle style) => TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: TextDirection.ltr,
  maxLines: 1,
)..layout();

/// The label style of a chart in [fontFamily].
TextStyle chartLabelStyle(String? fontFamily) =>
    TextStyle(fontSize: _labelFontSize, color: ChartColors.label, fontFamily: fontFamily, height: 1, letterSpacing: 0);

/// Paints a [ChartLayout]: split lines, the gradient area, the line and its symbols, the axis labels.
class AppChartPainter extends CustomPainter {
  AppChartPainter(this.options, {this.fontFamily, this.hovered});

  final ChartOptions options;
  final String? fontFamily;

  /// The hovered point (its symbol is drawn enlarged, ECharts' `emphasis.scale`).
  final int? hovered;

  @override
  void paint(Canvas canvas, Size size) {
    final style = chartLabelStyle(fontFamily);
    final l = ChartLayout.of(options, size, style);
    // ECharts draws into its container: what overflows it (the edge date labels) is cut off.
    canvas.clipRect(Offset.zero & size);
    final p = l.plot;
    final crisp = echartsCrisp;
    final thin = Paint()
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // y split lines (solid, light), at every tick.
    thin.color = ChartColors.splitLineLight;
    for (final t in l.yTicks) {
      final y = crisp(l.yOf(t));
      canvas.drawLine(Offset(p.left, y), Offset(p.right, y), thin);
    }
    // xAxis[1]: solid darker lines at the seed categories that are not empty.
    final seed = options.markLineSeedData;
    thin.color = ChartColors.splitLineDark;
    for (var i = 0; i < seed.length; i++) {
      if (!options.innerSplitLine(i, seed[i])) continue;
      final x = crisp(seed.length == 1 ? p.center.dx : p.left + i * p.width / (seed.length - 1));
      canvas.drawLine(Offset(x, p.top), Offset(x, p.bottom), thin);
    }
    // xAxis[0]: dashed light lines ([10, 10]) at the first and the last date.
    thin.color = ChartColors.splitLineLight;
    for (var i = 0; i < l.xs.length; i++) {
      if (!options.outerSplitLine(i)) continue;
      final x = crisp(l.xs[i]);
      for (var y = p.top; y < p.bottom; y += 20) {
        canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 10, p.bottom)), thin);
      }
    }

    // The series: runs of consecutive points (a missing value breaks the line).
    final runs = <List<Offset>>[];
    for (var i = 0; i < l.values.length; i++) {
      final pt = l.pointOf(i);
      if (pt == null) {
        if (runs.isNotEmpty && runs.last.isNotEmpty) runs.add([]);
        continue;
      }
      if (runs.isEmpty) runs.add([]);
      runs.last.add(pt);
    }
    final (c0, c1) = options.areaColors;
    for (final run in runs.where((r) => r.isNotEmpty)) {
      final area = Path()..moveTo(run.first.dx, p.bottom);
      for (final pt in run) {
        area.lineTo(pt.dx, pt.dy);
      }
      area
        ..lineTo(run.last.dx, p.bottom)
        ..close();
      final bounds = area.getBounds();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_areaOpacity(c0), _areaOpacity(c1)],
          ).createShader(bounds.height < 1 ? bounds.inflate(0.5) : bounds),
      );
      final line = Path()..moveTo(run.first.dx, run.first.dy);
      for (final pt in run.skip(1)) {
        line.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(
        line,
        Paint()
          ..color = options.lineColor
          ..strokeWidth = _lineWidth
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.bevel,
      );
    }
    // emptyCircle symbols.
    for (var i = 0; i < l.values.length; i++) {
      final pt = l.pointOf(i);
      if (pt == null || !l.symbols[i]) continue;
      final r = _symbolSize / 2 * (i == hovered ? 1.5 : 1);
      canvas
        ..drawCircle(pt, r, Paint()..color = ChartColors.symbolInner)
        ..drawCircle(
          pt,
          r,
          Paint()
            ..color = options.lineColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
    }

    // y labels, right-aligned `margin` left of the plot, centred on their tick; `hideOverlap` drops a label (the
    // fixed maximum, which comes last) that would overlap one already shown.
    final shownY = <double>[];
    for (var i = 0; i < l.yTicks.length; i++) {
      final y = l.yOf(l.yTicks[i]);
      if (shownY.any((s) => (s - y).abs() < _labelBoxHeight)) continue;
      shownY.add(y);
      final tp = _painter(l.yLabels[i], style);
      tp.paint(canvas, Offset(p.left - _labelMargin - tp.width, y - tp.height / 2));
    }
    // x labels, centred under their category.
    for (final x in l.xLabels.where((x) => x.visible)) {
      final tp = _painter(x.text, style);
      tp.paint(canvas, Offset(x.x - tp.width / 2, p.bottom + _labelMargin + (_labelBoxHeight - tp.height) / 2));
    }
  }

  @override
  bool shouldRepaint(AppChartPainter old) =>
      old.options != options || old.fontFamily != fontFamily || old.hovered != hovered;
}

/// The chart with ECharts' item tooltip: hovering a symbol shows the date and the value (and the price on token
/// charts) in a white box 8 px above the point, with ECharts' shadow and arrow.
class AppChartCanvas extends StatefulWidget {
  const AppChartCanvas({super.key, required this.options});

  final ChartOptions options;

  @override
  State<AppChartCanvas> createState() => _AppChartCanvasState();
}

class _AppChartCanvasState extends State<AppChartCanvas> {
  int? _hovered;

  /// How far from a symbol's centre the pointer still hovers it (the symbol, enlarged on hover).
  static const _hitRadius = 5.0;

  void _hover(Offset local, Size size, String? font) {
    final l = ChartLayout.of(widget.options, size, chartLabelStyle(font));
    int? hit;
    var best = double.infinity;
    for (var i = 0; i < l.values.length; i++) {
      final pt = l.pointOf(i);
      if (pt == null || !l.symbols[i]) continue;
      final d = (pt - local).distance;
      if (d <= _hitRadius && d < best) {
        best = d;
        hit = i;
      }
    }
    if (hit != _hovered) setState(() => _hovered = hit);
  }

  @override
  Widget build(BuildContext context) {
    final font = DefaultTextStyle.of(context).style.fontFamily;
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest;
        final hovered = _hovered;
        Widget? tooltip;
        if (hovered != null && hovered < widget.options.source.length) {
          final l = ChartLayout.of(widget.options, size, chartLabelStyle(font));
          final pt = l.pointOf(hovered);
          final row = widget.options.source[hovered];
          if (pt != null) {
            tooltip = _ChartTooltip(
              anchor: pt,
              content: widget.options.tooltip(widget.options.formatXLabel('${row['date'] ?? ''}'), row),
              font: font,
            );
          }
        }
        return MouseRegion(
          onHover: (e) => _hover(e.localPosition, size, font),
          onExit: (_) => setState(() => _hovered = null),
          child: Semantics(
            image: true,
            label: 'Chart',
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: AppChartPainter(widget.options, fontFamily: font, hovered: hovered),
                  ),
                ),
                ?tooltip,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// ECharts' HTML tooltip at `position: 'top'`: `padding: [8, 12, 8, 12]`, radius 4, no border, line height 21 px,
/// shadow `1px 2px 10px rgba(0,0,0,.2)`, a 6 px arrow under the box, `8 px` above the symbol's box.
class _ChartTooltip extends StatelessWidget {
  const _ChartTooltip({required this.anchor, required this.content, this.font});

  final Offset anchor;
  final ChartTooltipContent content;
  final String? font;

  @override
  Widget build(BuildContext context) {
    TextStyle s(double size, Color color) =>
        TextStyle(fontSize: size, height: 21 / size, color: color, fontFamily: font, letterSpacing: 0);
    final price = content.price;
    final value = Text.rich(
      TextSpan(
        style: s(14, ChartColors.tooltipValue),
        children: [
          TextSpan(text: content.value),
          if (price != null) ...[
            const TextSpan(text: ' '),
            const WidgetSpan(child: SizedBox(width: 4)),
            TextSpan(text: '( ', style: s(12, ChartColors.tooltipName)),
            TextSpan(text: '~\$$price', style: s(12, ChartColors.tooltipPrice)),
            TextSpan(text: ' )', style: s(12, ChartColors.tooltipName)),
          ],
        ],
      ),
      maxLines: 1,
      softWrap: false,
    );
    final box = Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: ChartColors.tooltipBackground,
        borderRadius: BorderRadius.circular(4),
        boxShadow: [BoxShadow(color: ChartColors.tooltipShadow, blurRadius: 10, offset: const Offset(1, 2))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(content.name, style: s(12, ChartColors.tooltipName), maxLines: 1, softWrap: false),
          value,
        ],
      ),
    );
    return Positioned(
      left: anchor.dx,
      top: anchor.dy - _symbolSize / 2 - 8,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1),
        child: IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Positioned(
                bottom: -3,
                child: Transform.rotate(
                  angle: math.pi / 4,
                  child: Container(width: 6, height: 6, color: ChartColors.tooltipBackground),
                ),
              ),
              box,
            ],
          ),
        ),
      ),
    );
  }
}
