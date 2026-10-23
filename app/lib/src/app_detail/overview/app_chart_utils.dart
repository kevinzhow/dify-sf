/// web/app/components/app/overview/app-chart-utils.ts (Dify 1.17.1): the statistics rows, Dify's empty-chart
/// fallback, the summary numbers and the ECharts option Dify builds, as a plain description that [AppChartCanvas]
/// paints.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../design/dify_palette.dart';

/// One statistics row (`{date, <value fields>, total_price?, currency?}`): the server's JSON, or a fallback row.
typedef ChartRow = Map<String, Object?>;

/// `ColorType`.
enum ChartColorType { green, orange, blue }

/// `ChartType` with its `CHART_TYPE_CONFIG` entry.
enum ChartType {
  messages(ChartColorType.green),
  conversations(ChartColorType.green),
  endUsers(ChartColorType.orange),
  costs(ChartColorType.blue, showTokens: true),
  workflowCosts(ChartColorType.blue, showTokens: true);

  const ChartType(this.colorType, {this.showTokens = false});
  final ChartColorType colorType;
  final bool showTokens;
}

/// The chart colours of a [ChartColorType] (`COLOR_TYPE_MAP`); the rest of the chart's literals are
/// [DifyChartColors].
abstract final class ChartColors {
  static Color line(ChartColorType t) => switch (t) {
    ChartColorType.green => DifyChartColors.greenLine,
    ChartColorType.orange => DifyChartColors.orangeLine,
    ChartColorType.blue => DifyChartColors.blueLine,
  };

  static (Color, Color) area(ChartColorType t) => switch (t) {
    ChartColorType.green => (DifyChartColors.greenAreaTop, DifyChartColors.greenAreaBottom),
    ChartColorType.orange => (DifyChartColors.orangeAreaTop, DifyChartColors.orangeAreaBottom),
    ChartColorType.blue => (DifyChartColors.blueAreaTop, DifyChartColors.blueAreaBottom),
  };
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// dayjs's `MMM D, YYYY` (`commonDateFormat`).
String formatChartDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// Two digits.
String _pad2(int v) => v.toString().padLeft(2, '0');

/// dayjs's `YYYY-MM-DD HH:mm` (`queryDateFormat`).
String formatQueryDate(DateTime d) => '${d.year}-${_pad2(d.month)}-${_pad2(d.day)} ${_pad2(d.hour)}:${_pad2(d.minute)}';

/// `dayjs(value)` for the strings the charts meet: `YYYY-MM-DD[ HH:mm[:ss]]` (the server's dates, the queries) and
/// `MMM D, YYYY` (the fallback rows). Local time; null when unparseable (dayjs's Invalid Date).
DateTime? parseChartDate(String value) {
  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$').firstMatch(value.trim());
  if (iso != null) {
    int g(int i) => int.parse(iso.group(i) ?? '0');
    return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
  }
  final mdy = RegExp(r'^([A-Za-z]{3})[a-z]* (\d{1,2}), (\d{4})$').firstMatch(value.trim());
  if (mdy != null) {
    final m = _months.indexWhere((x) => x.toLowerCase() == mdy.group(1)!.toLowerCase());
    if (m >= 0) return DateTime(int.parse(mdy.group(3)!), m + 1, int.parse(mdy.group(2)!));
  }
  return null;
}

/// dayjs `end.diff(start, 'day')`: whole days, truncated toward zero.
int _diffDays(DateTime end, DateTime start) =>
    (end.difference(start).inMicroseconds / Duration.microsecondsPerDay).truncate();

/// `defaultPeriod`: the last 7 days as `MMM D, YYYY` (used when the period has no query: "All time").
({String start, String end}) defaultChartPeriod([DateTime? now]) {
  final n = now ?? DateTime.now();
  return (start: formatChartDate(n.subtract(const Duration(days: 7))), end: formatChartDate(n));
}

/// `getDefaultChartData`: a zero row per day from [start] (`diffDays` rows, at least one), dated `MMM D, YYYY`.
List<ChartRow> getDefaultChartData({required String start, required String end, String key = 'count'}) {
  final s = parseChartDate(start), e = parseChartDate(end);
  final diff = s == null || e == null ? 0 : _diffDays(e, s);
  final length = diff == 0 ? 1 : diff;
  return [
    for (var i = 0; i < length; i++)
      {'date': s == null ? 'Invalid Date' : formatChartDate(DateTime(s.year, s.month, s.day + i)), key: 0},
  ];
}

/// JavaScript's `Number.parseFloat(String(v ?? 0))`.
double _parseFloat(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  final m = RegExp(r'^\s*[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?').firstMatch('$v');
  return m == null ? double.nan : double.parse(m.group(0)!.trim());
}

/// Decimal.js's `Decimal.Value` of a row field (`row[field] ?? 0`) as a number.
double _value(Object? v) => switch (v) {
  null => 0,
  num n => n.toDouble(),
  String s => double.tryParse(s.trim()) ?? double.nan,
  _ => double.nan,
};

/// `getChartValueField`: [valueKey], else the first field whose name contains `count`, else `count`.
String getChartValueField(List<ChartRow> statistics, [String? valueKey]) {
  if (valueKey != null) return valueKey;
  final first = statistics.isEmpty ? const <String, Object?>{} : statistics.first;
  return first.keys.where((k) => k.contains('count')).firstOrNull ?? 'count';
}

/// `hasNonZeroChartData`.
bool hasNonZeroChartData(List<ChartRow> statistics, String yField) => statistics.any((row) {
  final v = _parseFloat(row[yField] ?? 0);
  return v.isFinite && v != 0;
});

/// Exact decimal sum (Decimal.js `Decimal.sum`) of [values], as a double.
double _sum(Iterable<double> values) {
  // Sum in scaled integers where possible, avoiding binary rounding (0.1 + 0.2).
  var scale = 0;
  final list = values.toList();
  for (final v in list) {
    if (!v.isFinite) return double.nan;
    final s = v.toString();
    final dot = s.indexOf('.');
    if (s.contains('e') || s.contains('E')) return list.fold(0.0, (a, b) => a + b);
    if (dot >= 0) scale = math.max(scale, s.length - dot - 1);
  }
  if (scale > 12) return list.fold(0.0, (a, b) => a + b);
  final f = math.pow(10, scale);
  var total = BigInt.zero;
  for (final v in list) {
    total += BigInt.from((v * f).round());
  }
  return total.toDouble() / f;
}

/// JavaScript's `String(number)` for the values Dify prints raw (`1`, `1.5`, `0.25`).
String jsNumber(num v) {
  if (v is int) return '$v';
  final d = v.toDouble();
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d > 0 ? 'Infinity' : '-Infinity';
  if (d == d.truncateToDouble() && d.abs() < 1e21) return d.toStringAsFixed(0);
  return '$d';
}

/// `Number.prototype.toLocaleString()` in en-US: grouped thousands, at most three fraction digits (half away from
/// zero).
String toLocaleString(double v, {int maxFraction = 3, int minFraction = 0}) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? '∞' : '-∞';
  final negative = v < 0;
  final fixed = _roundHalfAway(v.abs(), maxFraction).toStringAsFixed(maxFraction);
  var (whole, frac) = switch (fixed.split('.')) {
    [final w, final f] => (w, f),
    [final w] => (w, ''),
    _ => (fixed, ''),
  };
  while (frac.length > minFraction && frac.endsWith('0')) {
    frac = frac.substring(0, frac.length - 1);
  }
  final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final out = frac.isEmpty ? grouped : '$grouped.$frac';
  return negative && out.replaceAll(RegExp(r'[0.,]'), '').isNotEmpty ? '-$out' : out;
}

double _roundHalfAway(double v, int digits) {
  final f = math.pow(10, digits);
  return (v * f + 1e-9).roundToDouble() / f;
}

/// utils/format.ts `formatNumber` for the integers it gets here: grouped thousands.
String _formatNumber(num n) => n == 0 ? '0' : toLocaleString(n.toDouble(), maxFraction: 20);

/// `getSummaryValue`: the sum (or the average with [isAvg]) of [yField]; cost charts print `<1000` raw and
/// thousands as `<n>k`, the others as a localised number followed by [unit].
String getSummaryValue({
  required ChartType chartType,
  required List<ChartRow> statistics,
  required String yField,
  bool isAvg = false,
  String unit = '',
}) {
  final values = [for (final row in statistics) _value(row[yField])];
  final divisor = values.isEmpty ? 1 : values.length;
  final sum = _sum(values);
  final data = isAvg ? sum / divisor : sum;
  if (chartType == ChartType.costs || chartType == ChartType.workflowCosts) {
    return data < 1000 ? jsNumber(data) : '${_formatNumber((data / 1000).round())}k';
  }
  return '${toLocaleString(data)} $unit'.trim();
}

/// `getTokenSummary`: the summed `total_price` as US dollars with four decimals.
String getTokenSummary(List<ChartRow> statistics) {
  final total = _sum([for (final row in statistics) _parseFloat(row['total_price'] ?? '0')]);
  if (total.isNaN) return r'$NaN';
  final s = toLocaleString(total.abs(), maxFraction: 4, minFraction: 4);
  return total < 0 ? '-\$$s' : '\$$s';
}

/// The tooltip text of a point (`getTooltipContent`): the date over the value, and for token charts the price.
class ChartTooltipContent {
  const ChartTooltipContent({required this.name, required this.value, this.price});
  final String name;
  final String value;

  /// `get(row, 'total_price', 0)` as Dify prints it; null when the chart shows no price.
  final String? price;

  @override
  String toString() => price == null ? '$name\n$value' : '$name\n$value (~\$$price)';
}

/// What Dify's `buildChartOptions` hands ECharts, as a description: the dataset, the grid, the two x axes' split
/// lines, the y axis maximum, the series colours and the tooltip.
class ChartOptions {
  ChartOptions._({
    required this.dimensions,
    required this.source,
    required this.chartType,
    required this.yField,
    required this.yMax,
    required this.markLineSeedData,
  });

  final List<String> dimensions;
  final List<ChartRow> source;
  final ChartType chartType;
  final String yField;

  /// `yAxis.max`; null: `'dataMax'`.
  final double? yMax;

  /// The second x axis's categories (`getMarkLineSeedData`).
  final List<String> markLineSeedData;

  /// `grid: { top: 16, right: 0, bottom: 10, left: 0, containLabel: true }`.
  ({double top, double right, double bottom, double left}) get grid => (top: 16, right: 0, bottom: 10, left: 0);

  Color get lineColor => ChartColors.line(chartType.colorType);
  (Color, Color) get areaColors => ChartColors.area(chartType.colorType);

  /// `xAxis[0].axisLabel.formatter`: `dayjs(value).format('MMM D, YYYY')`.
  String formatXLabel(String value) => switch (parseChartDate(value)) {
    final d? => formatChartDate(d),
    null => 'Invalid Date',
  };

  /// `xAxis[0].splitLine.interval`: the dashed light lines, at the first and the last date.
  bool outerSplitLine(int index) => index == 0 || index == source.length - 1;

  /// `xAxis[1].splitLine.interval`: the solid darker lines, at the seed categories that are not empty.
  bool innerSplitLine(int index, String value) => value.isNotEmpty;

  /// `series[0].tooltip.formatter` for the point named [name] holding [data].
  ChartTooltipContent tooltip(String name, ChartRow? data) {
    final row = data ?? {'date': name};
    final raw = row[yField] ?? 0;
    final value = raw is num ? jsNumber(raw) : '$raw';
    if (!chartType.showTokens || !row.containsKey('total_price')) {
      return ChartTooltipContent(name: name, value: value);
    }
    final price = row['total_price'] ?? 0;
    return ChartTooltipContent(name: name, value: value, price: price is num ? jsNumber(price) : '$price');
  }
}

/// `buildChartOptions`.
ChartOptions buildChartOptions({
  required List<ChartRow> statistics,
  required ChartType chartType,
  required String yField,
  double? yMax,
}) {
  final n = statistics.length;
  final markLineLength = n >= 2 ? n - 2 : n;
  return ChartOptions._(
    dimensions: ['date', yField],
    source: statistics,
    chartType: chartType,
    yField: yField,
    yMax: yMax,
    markLineSeedData: ['', for (var i = 0; i < markLineLength; i++) '1', ''],
  );
}

/// The y value of [row] the line draws (ECharts reads the dataset dimension; missing or non-numeric is no point).
double? chartRowValue(ChartRow row, String yField) {
  final v = _parseFloat(row[yField]);
  return row[yField] == null || !v.isFinite ? null : v;
}
