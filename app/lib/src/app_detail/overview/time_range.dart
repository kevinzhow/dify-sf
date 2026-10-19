/// The Overview's period (`PeriodParams`, app-chart.tsx) and its picker on the community edition
/// (`[appId]/overview/long-time-range-picker.tsx` over log/filter.tsx's `TIME_PERIOD_MAPPING`), Dify 1.17.1.
///
/// The Cloud edition's picker (`time-range-picker/`: today, 7 or 30 days, or a custom range of at most 30 days) is
/// not part of dify-sf, which is a self-hosted (community) Dify.
library;

import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'app_chart_utils.dart';
import '../../design/widgets/widgets.dart';

/// `PeriodParams`: the picker's label and the statistics query (`YYYY-MM-DD HH:mm`); no query: all time.
typedef PeriodParams = ({String name, ({String start, String end})? query});

/// log/filter.tsx `TIME_PERIOD_MAPPING` for [today] (Dify computes it once, when the module loads): the key, the
/// number of days back (0: today, -1: all time) and the `appLog:filter.period.*` name.
Map<String, ({int value, String name})> timePeriodMapping(DateTime today) {
  int daysSince(DateTime from) =>
      DateTime(today.year, today.month, today.day).difference(DateTime(from.year, from.month, from.day)).inDays;
  return {
    '1': (value: 0, name: 'today'),
    '2': (value: 7, name: 'last7days'),
    '3': (value: 28, name: 'last4weeks'),
    '4': (value: daysSince(subtractMonths(today, 3)), name: 'last3months'),
    '5': (value: daysSince(subtractMonths(today, 12)), name: 'last12months'),
    '6': (value: today.day - 1, name: 'monthToDate'),
    '7': (value: daysSince(DateTime(today.year, (today.month - 1) ~/ 3 * 3 + 1)), name: 'quarterToDate'),
    '8': (value: daysSince(DateTime(today.year)), name: 'yearToDate'),
    '9': (value: -1, name: 'allTime'),
  };
}

/// dayjs `subtract(n, 'month')`: the same day of the month, clamped to the target month's last day.
DateTime subtractMonths(DateTime d, int months) {
  final first = DateTime(d.year, d.month - months);
  final last = DateTime(first.year, first.month + 1, 0).day;
  return DateTime(first.year, first.month, d.day > last ? last : d.day, d.hour, d.minute, d.second);
}

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _endOfDay(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

/// LongTimeRangePicker's `handleSelect`: the period of mapping entry [value] named [name] on [today].
PeriodParams longTimePeriod({required int value, required String name, required DateTime today}) {
  if (value == -1) return (name: DifyI18n.tr('appLog', 'filter.period.allTime'), query: null);
  final start = value == 0 ? _startOfDay(today) : _startOfDay(today.subtract(Duration(days: value)));
  return (name: name, query: (start: formatQueryDate(start), end: formatQueryDate(_endOfDay(today))));
}

/// chart-view.tsx's first period on the community edition: the last 7 days.
PeriodParams defaultOverviewPeriod(DateTime today) => (
  name: DifyI18n.tr('appLog', 'filter.period.last7days'),
  query: (
    start: formatQueryDate(_startOfDay(today.subtract(const Duration(days: 7)))),
    end: formatQueryDate(_endOfDay(today)),
  ),
);

/// LongTimeRangePicker: dify-ui's Select (`mt-0 w-fit max-w-none`) with the mapping's periods, "Last 7 Days" first.
class LongTimeRangePicker extends StatefulWidget {
  const LongTimeRangePicker({super.key, required this.today, required this.onSelect});

  /// Dify's module-level `today`.
  final DateTime today;
  final ValueChanged<PeriodParams> onSelect;

  @override
  State<LongTimeRangePicker> createState() => _LongTimeRangePickerState();
}

class _LongTimeRangePickerState extends State<LongTimeRangePicker> {
  String _value = '2';

  @override
  Widget build(BuildContext context) {
    final mapping = timePeriodMapping(widget.today);
    final items = [
      for (final e in mapping.entries) (value: e.key, label: DifyI18n.tr('appLog', 'filter.period.${e.value.name}')),
    ];
    final selected = items.where((i) => i.value == _value).firstOrNull;
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled);
    final itemStyle = difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary);
    final base = DefaultTextStyle.of(context).style;
    double width(String s, TextStyle st) => (TextPainter(
      text: TextSpan(text: s, style: base.merge(st)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout()).width;
    final text = selected?.label ?? DifyI18n.tr('common', 'placeholder.select');
    // `w-fit`: the text, `gap-0.5` and the 16 px chevron inside `px-3`.
    final triggerWidth = (width(text, style) + 2 + 16 + 24).ceilToDouble();
    // The popup is at least as wide as the trigger and fits its widest item (`px-2`, the text's `px-1 me-1`, the
    // 16 px indicator, the list's `p-1`, the 0.5 px border).
    final itemWidth = items.fold(0.0, (m, i) => width(i.label, itemStyle) > m ? width(i.label, itemStyle) : m);
    final popupWidth = (itemWidth + 16 + 12 + 16 + 8 + 1).ceilToDouble();
    return DifySelect<String>(
      key: const ValueKey('overview-period'),
      value: selected?.value,
      width: triggerWidth,
      popupWidth: popupWidth > triggerWidth ? popupWidth : triggerWidth,
      placeholder: DifyI18n.tr('common', 'placeholder.select'),
      options: items,
      onChanged: (v) {
        final item = items.where((i) => i.value == v).firstOrNull;
        if (item == null) return;
        setState(() => _value = v);
        final period = mapping[v]!;
        widget.onSelect(
          longTimePeriod(
            value: period.value,
            name: item.label.isEmpty ? DifyI18n.tr('appLog', 'filter.period.allTime') : item.label,
            today: widget.today,
          ),
        );
      },
    );
  }
}
