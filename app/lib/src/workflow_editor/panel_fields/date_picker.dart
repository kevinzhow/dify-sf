/// base/date-and-time-picker as the node panels use it: the calendar popup ([DifyCalendar]) and the day helpers
/// (`YYYY-MM-DD` calendar days, dayjs-style display formats).
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';

String _time(String key) => DifyI18n.tr('time', key);

/// The `time` namespace's month keys, January first.
const calendarMonthKeys = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// The `time` namespace's day-of-week keys, Sunday first.
const calendarDayKeys = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// `YYYY-MM-DD` as a calendar day, or null.
DateTime? parseDateOnly(Object? raw) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw is String ? raw.trim() : '');
  if (m == null) return null;
  return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

String _pad(int n, [int w = 2]) => '$n'.padLeft(w, '0');

/// The day as `YYYY-MM-DD`.
String formatDateOnly(DateTime d) => '${_pad(d.year, 4)}-${_pad(d.month)}-${_pad(d.day)}';

/// dayjs `format` for the date tokens Dify's display formats use (`YYYY`, `MMMM`, `MMM`, `MM`, `M`, `DD`, `D`),
/// month names from the `time` namespace.
String formatDisplayDate(DateTime d, String format) {
  final month = _time('months.${calendarMonthKeys[d.month - 1]}');
  return format.replaceAllMapped(RegExp(r'YYYY|MMMM|MMM|MM|M|DD|D'), (m) {
    return switch (m[0]) {
      'YYYY' => _pad(d.year, 4),
      'MMMM' => month,
      'MMM' => month.length > 3 ? month.substring(0, 3) : month,
      'MM' => _pad(d.month),
      'M' => '${d.month}',
      'DD' => _pad(d.day),
      _ => '${d.day}',
    };
  });
}

/// base/date-and-time-picker's DatePicker popup: `w-63 rounded-xl border-[0.5px] bg-components-panel-bg shadow-lg`,
/// the month header with previous / next buttons, the days of the week and a 6-week grid (calendar/item.tsx); a day
/// click reports it ([onSelect]). [footer] (the time picker, Now / OK) goes under the grid.
class DifyCalendar extends StatefulWidget {
  const DifyCalendar({super.key, required this.selected, required this.onSelect, this.footer});
  final DateTime? selected;
  final ValueChanged<DateTime> onSelect;
  final Widget? footer;

  @override
  State<DifyCalendar> createState() => _DifyCalendarState();
}

class _DifyCalendarState extends State<DifyCalendar> {
  late DateTime _month = DateTime((widget.selected ?? DateTime.now()).year, (widget.selected ?? DateTime.now()).month);

  void _shift(int by) => setState(() => _month = DateTime(_month.year, _month.month + by));

  @override
  Widget build(BuildContext context) {
    final first = DateTime(_month.year, _month.month);
    final start = first.subtract(Duration(days: first.weekday % 7));
    final today = DateTime.now();
    bool same(DateTime a, DateTime? b) => b != null && a.year == b.year && a.month == b.month && a.day == b.day;
    return Semantics(
      role: SemanticsRole.dialog,
      explicitChildNodes: true,
      child: Container(
        width: 252,
        margin: const EdgeInsets.only(top: 4),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 2,
                          children: [
                            DifyText(
                              '${_time('months.${calendarMonthKeys[_month.month - 1]}')} ${_month.year}',
                              DifyType.systemMdSemibold,
                            ),
                            RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textTertiary),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (final (icon, by) in const [('arrow-up-s-line', -1), ('arrow-down-s-line', 1)])
                    DifyIconButton(
                      label: icon,
                      onPressed: () => _shift(by),
                      icon: RemixIcon(icon, size: 18, color: DifyColors.textSecondary),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: DifyColors.dividerRegular, width: 0.5)),
              ),
              child: Row(
                children: [
                  for (final d in calendarDayKeys)
                    Expanded(
                      child: DifyText(
                        _time('daysInWeek.$d'),
                        DifyType.system2xsMedium,
                        color: DifyColors.textTertiary,
                        align: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                spacing: 2,
                children: [
                  for (var w = 0; w < 6; w++)
                    Row(
                      spacing: 2,
                      children: [
                        for (var i = 0; i < 7; i++)
                          () {
                            final day = DateTime(start.year, start.month, start.day + w * 7 + i);
                            return Expanded(
                              child: _DayItem(
                                day: day,
                                inMonth: day.month == _month.month,
                                selected: same(day, widget.selected),
                                today: same(day, today),
                                onTap: () => widget.onSelect(day),
                              ),
                            );
                          }(),
                      ],
                    ),
                ],
              ),
            ),
            ?widget.footer,
          ],
        ),
      ),
    );
  }
}

/// calendar/item.tsx: `rounded-lg px-1 py-2 system-sm-medium`, primary when selected, a dot under today.
class _DayItem extends StatelessWidget {
  const _DayItem({
    required this.day,
    required this.inMonth,
    required this.selected,
    required this.today,
    required this.onTap,
  });
  final DateTime day;
  final bool inMonth, selected, today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onTap,
    semanticLabel: formatDateOnly(day),
    builder: (context, hovered, focused) => Container(
      height: 36,
      decoration: BoxDecoration(
        color: selected
            ? DifyColors.componentsButtonPrimaryBg
            : hovered
            ? DifyColors.stateBaseHover
            : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          DifyText(
            '${day.day}',
            DifyType.systemSmMedium,
            color: selected
                ? DifyColors.componentsButtonPrimaryText
                : inMonth || hovered
                ? DifyColors.textSecondary
                : DifyColors.textQuaternary,
          ),
          if (today)
            Positioned(
              bottom: 4,
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: DifyColors.componentsButtonPrimaryBg,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
