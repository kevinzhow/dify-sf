/// base/date-and-time-picker/time-picker (with its Header, Options and Footer) and base/timezone-label, as the
/// schedule trigger uses them: a 12-hour time of day.
library;

import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/css_metrics.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import 'schedule_timezone.dart';

/// A time of day (24-hour [hour]).
typedef TimeOfDayValue = ({int hour, int minute});

final _time12 = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?\s?(AM|PM)$', caseSensitive: false);
final _time24 = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?$');

/// toDayjs for a time-only string (`h:mm A`, `HH:mm`); null when it is none.
TimeOfDayValue? parseTimeOfDay(String? value) {
  if (value == null) return null;
  final s = value.trim();
  if (_time12.firstMatch(s) case final m?) {
    final h = int.parse(m[1]!), min = int.parse(m[2]!);
    if (h < 1 || h > 12 || min > 59) return null;
    final pm = m[4]!.toUpperCase() == 'PM';
    return (hour: h % 12 + (pm ? 12 : 0), minute: min);
  }
  if (_time24.firstMatch(s) case final m?) {
    final h = int.parse(m[1]!), min = int.parse(m[2]!);
    if (h > 23 || min > 59) return null;
    return (hour: h, minute: min);
  }
  return null;
}

int _hour12(int hour) => hour % 12 == 0 ? 12 : hour % 12;
String _two(int n) => n.toString().padLeft(2, '0');

/// dayjs `format('hh:mm A')`.
String formatTimeHhMmA(TimeOfDayValue t) => '${_two(_hour12(t.hour))}:${_two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';

/// dayjs `format('h:mm A')` (the schedule trigger's stored form).
String formatTimeHMmA(TimeOfDayValue t) => '${_hour12(t.hour)}:${_two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';

/// TimezoneLabel: the timezone's `UTC±h` (`system-sm-regular text-text-tertiary`, [inline]: quaternary).
class TimezoneLabel extends StatelessWidget {
  const TimezoneLabel({super.key, required this.timezone, this.inline = false, this.style});
  final String timezone;
  final bool inline;

  /// The call site's text class (`text-xs` in the time picker).
  final DifyTextStyle? style;

  @override
  Widget build(BuildContext context) {
    final offset = convertTimezoneToOffsetStr(timezone);
    return DifyTooltip(
      content: Text('Timezone: $timezone ($offset)'),
      child: DifyText(
        offset,
        style ?? DifyType.systemSmRegular,
        color: inline ? DifyColors.textQuaternary : DifyColors.textTertiary,
      ),
    );
  }
}

/// TimePicker: the trigger (`rounded-lg bg-components-input-bg-normal px-2 py-1`, the time as `hh:mm A`, the
/// timezone label with [showTimezone], a clock icon) opening the "Pick Time" popup: hour, minute and AM / PM
/// columns, "Now" and "OK". The choice is reported on OK ([onChange] with null when nothing is chosen) or Now (the
/// current time from [now]).
class TimePicker extends StatefulWidget {
  const TimePicker({
    super.key,
    required this.value,
    required this.onChange,
    required this.now,
    this.onClear,
    this.timezone,
    this.placeholder,
    this.title,
    this.notClearable = false,
    this.triggerFullWidth = false,
    this.showTimezone = false,
  });

  final String? value;
  final ValueChanged<TimeOfDayValue?> onChange;
  final VoidCallback? onClear;

  /// The current wall-clock time in [timezone].
  final DateTime Function() now;
  final String? timezone, placeholder, title;
  final bool notClearable, triggerFullWidth, showTimezone;

  @override
  State<TimePicker> createState() => _TimePickerState();
}

class _TimePickerState extends State<TimePicker> {
  final _floating = DifyFloatingController();
  bool _open = false, _hovered = false;
  late TimeOfDayValue? _selected = parseTimeOfDay(widget.value);

  @override
  void didUpdateWidget(TimePicker old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      final v = parseTimeOfDay(widget.value);
      if (v != null) _selected = v;
    }
  }

  void _openChanged(bool open) {
    setState(() {
      _open = open;
      if (open && widget.value != null) _selected = parseTimeOfDay(widget.value) ?? _selected;
    });
  }

  /// getSafeTimeObject: the selection, else the start of the day.
  TimeOfDayValue get _safe => _selected ?? (hour: 0, minute: 0);

  void _select(int hour12, int minute, bool pm) =>
      setState(() => _selected = (hour: hour12 % 12 + (pm ? 12 : 0), minute: minute));

  void _now() {
    final n = widget.now();
    final t = (hour: n.hour, minute: n.minute);
    setState(() => _selected = t);
    widget.onChange(t);
    _floating.close();
  }

  void _confirm() {
    widget.onChange(_selected);
    _floating.close();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final display = parseTimeOfDay(w.value);
    final displayText = display == null ? '' : formatTimeHhMmA(display);
    final placeholder = _open && _selected != null
        ? formatTimeHhMmA(_selected!)
        : w.placeholder ?? DifyI18n.tr('time', 'defaultPlaceholder');
    final clearable = (displayText.isNotEmpty || (_open && _selected != null)) && !w.notClearable;
    final showText = !_open && displayText.isNotEmpty;
    final textStyle = difyTextStyle(
      DifyType.systemXsRegular,
      showText ? DifyColors.componentsInputTextFilled : DifyColors.componentsInputTextPlaceholder,
    );
    return DifyPopover(
      controller: _floating,
      onOpenChange: _openChanged,
      placement: DifyPlacement.bottomStart,
      sideOffset: 0,
      surface: false,
      builder: (context, c) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: c.toggle,
          child: Container(
            width: w.triggerFullWidth ? double.infinity : 252,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _hovered ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Row(
              spacing: 2,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      showText ? displayText : placeholder,
                      style: textStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (w.showTimezone && w.timezone != null)
                  TimezoneLabel(timezone: w.timezone!, inline: true, style: DifyType.systemXsRegular),
                if (clearable && _hovered)
                  DifyPressable(
                    semanticLabel: DifyI18n.tr('common', 'operation.clear'),
                    onPressed: () {
                      setState(() => _selected = null);
                      if (!_open) w.onClear?.call();
                    },
                    builder: (context, hovered, _) => RemixIcon(
                      'close-circle-fill',
                      size: 16,
                      color: hovered ? DifyColors.textSecondary : DifyColors.textQuaternary,
                    ),
                  )
                else
                  RemixIcon(
                    'time-line',
                    size: 16,
                    color: _open || _hovered ? DifyColors.textSecondary : DifyColors.textQuaternary,
                  ),
              ],
            ),
          ),
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Container(
          width: 252,
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            boxShadow: DifyShadows.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: DifyColors.dividerRegular, width: Css.hairline),
                  ),
                ),
                child: DifyText(
                  w.title ?? DifyI18n.tr('time', 'title.pickTime'),
                  DifyType.systemMdSemibold,
                  color: DifyColors.textPrimary,
                ),
              ),
              _Options(
                selected: _selected,
                onHour: (h) => _select(h, _safe.minute, _safe.hour >= 12),
                onMinute: (m) => _select(_hour12(_safe.hour), m, _safe.hour >= 12),
                onPeriod: (pm) => _select(_hour12(_safe.hour), _safe.minute, pm),
              ),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: DifyColors.dividerRegular, width: Css.hairline),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: DifyButton(
                        variant: DifyButtonVariant.secondaryAccent,
                        size: DifyButtonSize.small,
                        onPressed: _now,
                        child: Text(DifyI18n.tr('time', 'operation.now')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DifyButton(
                        variant: DifyButtonVariant.primary,
                        size: DifyButtonSize.small,
                        onPressed: _confirm,
                        child: Text(DifyI18n.tr('time', 'operation.ok')),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Options: three `h-52` columns (`grid grid-cols-3 gap-x-1 p-2`) of 12 hours, 60 minutes and AM / PM.
class _Options extends StatelessWidget {
  const _Options({required this.selected, required this.onHour, required this.onMinute, required this.onPeriod});
  final TimeOfDayValue? selected;
  final ValueChanged<int> onHour, onMinute;
  final ValueChanged<bool> onPeriod;

  @override
  Widget build(BuildContext context) {
    final s = selected;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Expanded(
            child: _OptionList(
              labels: [for (var h = 1; h <= 12; h++) _two(h)],
              selected: s == null ? null : _hour12(s.hour) - 1,
              onSelect: (i) => onHour(i + 1),
            ),
          ),
          Expanded(
            child: _OptionList(
              labels: [for (var m = 0; m < 60; m++) _two(m)],
              selected: s?.minute,
              onSelect: onMinute,
            ),
          ),
          Expanded(
            child: _OptionList(
              labels: const ['AM', 'PM'],
              selected: s == null ? null : (s.hour >= 12 ? 1 : 0),
              onSelect: (i) => onPeriod(i == 1),
              autoScroll: false,
            ),
          ),
        ],
      ),
    );
  }
}

/// OptionList (`flex h-52 flex-col gap-y-0.5 overflow-y-auto pb-46`, no scrollbar) of OptionListItems (`rounded-md
/// px-1.5 py-1 system-xs-medium text-components-button-ghost-text`, selected or hovered
/// `bg-components-button-ghost-bg-hover`). The selected item is scrolled to the top on open (unless [autoScroll] is
/// false) and a clicked one is scrolled there smoothly.
class _OptionList extends StatefulWidget {
  const _OptionList({required this.labels, required this.selected, required this.onSelect, this.autoScroll = true});
  final List<String> labels;
  final int? selected;
  final ValueChanged<int> onSelect;
  final bool autoScroll;

  @override
  State<_OptionList> createState() => _OptionListState();
}

class _OptionListState extends State<_OptionList> {
  static const _item = 24.0, _gap = 2.0;
  late final _scroll = ScrollController(
    initialScrollOffset: widget.autoScroll && widget.selected != null ? widget.selected! * (_item + _gap) : 0,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _tap(int i) {
    if (_scroll.hasClients) {
      final target = (i * (_item + _gap)).clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.animateTo(target, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    }
    widget.onSelect(i);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 208,
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 184),
        child: Column(
          spacing: _gap,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, label) in widget.labels.indexed)
              DifyPressable(
                semanticLabel: label,
                onPressed: () => _tap(i),
                builder: (context, hovered, focused) => Container(
                  height: _item,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == widget.selected || hovered ? DifyColors.componentsButtonGhostBgHover : null,
                    borderRadius: BorderRadius.circular(DifyRadius.md),
                    border: focused ? Border.all(color: DifyColors.componentsInputBorderHover) : null,
                  ),
                  child: DifyText(label, DifyType.systemXsMedium, color: DifyColors.componentsButtonGhostText),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
