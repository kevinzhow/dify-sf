/// The tool form's date fields (nodes/tool/components/tool-date-picker.tsx, tool-date-range-picker.tsx) on a lean
/// port of Dify's DatePicker (base/date-and-time-picker: header, days of week, calendar items; `noConfirm`, no time
/// picker). Values are `YYYY-MM-DD` strings: calendar days, so no timezone shifts them.
library;

import 'package:flutter/material.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import 'tool_model.dart';

String _time(String key) => DifyI18n.tr('time', key);

String _display(DateTime? d) => d == null ? '' : formatDisplayDate(d, _time('dateFormats.display'));

/// A DatePicker trigger opening the calendar (`bottom-end`); [builder] draws the trigger from the open state.
class _DatePopover extends StatefulWidget {
  const _DatePopover({required this.selected, required this.onSelect, required this.builder});
  final DateTime? selected;
  final ValueChanged<DateTime> onSelect;
  final Widget Function(BuildContext context, DifyFloatingController controller) builder;

  @override
  State<_DatePopover> createState() => _DatePopoverState();
}

class _DatePopoverState extends State<_DatePopover> {
  final _controller = DifyFloatingController();

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _controller,
    placement: DifyPlacement.bottomEnd,
    builder: widget.builder,
    popupBuilder: (context) => DifyCalendar(
      selected: widget.selected,
      onSelect: (d) {
        _controller.close();
        widget.onSelect(d);
      },
    ),
  );
}

/// The clear button of date triggers: `size-4 rounded border-[0.5px] bg-components-button-secondary-bg` with
/// `i-ri-close-circle-fill`, shown on hover / focus.
class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.label, required this.visible, required this.onPressed});
  final String label;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onPressed,
    semanticLabel: label,
    builder: (context, hovered, focused) => Opacity(
      opacity: visible || focused || hovered ? 1 : 0,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: hovered ? DifyColors.componentsButtonSecondaryBgHover : DifyColors.componentsButtonSecondaryBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: DifyColors.componentsButtonSecondaryBorder, width: 0.5),
          boxShadow: DifyShadows.xs,
        ),
        child: RemixIcon(
          'close-circle-fill',
          size: 14,
          color: hovered ? DifyColors.textSecondary : DifyColors.textTertiary,
        ),
      ),
    ),
  );
}

/// ToolDatePicker: an `h-8 rounded-lg bg-components-input-bg-normal px-2` trigger with the calendar icon and the
/// date (or [placeholder], "Pick Date"), labelled `"<placeholder>: <date>"`; a clear button on hover sets ''.
/// Read-only: disabled, 60 % opacity, no clear.
class ToolDatePicker extends StatefulWidget {
  const ToolDatePicker({
    super.key,
    required this.value,
    required this.onChange,
    this.placeholder,
    this.readOnly = false,
  });

  final Object? value;
  final ValueChanged<String> onChange;
  final String? placeholder;
  final bool readOnly;

  @override
  State<ToolDatePicker> createState() => _ToolDatePickerState();
}

class _ToolDatePickerState extends State<ToolDatePicker> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final date = parseDateOnly(w.value);
    final placeholder = w.placeholder == null || w.placeholder!.isEmpty ? _time('operation.pickDate') : w.placeholder!;
    final shown = _display(date);
    final label = '$placeholder${shown.isNotEmpty ? ': $shown' : ''}';
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          _DatePopover(
            selected: date,
            onSelect: (d) => w.onChange(formatDateOnly(d)),
            builder: (context, c) => Opacity(
              opacity: w.readOnly ? 0.6 : 1,
              child: DifyPressable(
                disabled: w.readOnly,
                onPressed: c.toggle,
                semanticLabel: label,
                builder: (context, hovered, focused) => Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: DifyFocusDecoration(
                    color: hovered && !w.readOnly || c.isOpen
                        ? DifyColors.stateBaseHover
                        : DifyColors.componentsInputBgNormal,
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                    boxShadow: difyFocusRing(focused),
                  ),
                  child: Row(
                    spacing: 2,
                    children: [
                      Padding(
                        padding: EdgeInsets.all(1),
                        child: RemixIcon('calendar-line', size: 14, color: DifyColors.textTertiary),
                      ),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: 4, right: date != null ? 20 : 4),
                          child: DifyText(
                            shown.isNotEmpty ? shown : placeholder,
                            DifyType.systemSmRegular,
                            color: date == null
                                ? DifyColors.componentsInputTextPlaceholder
                                : DifyColors.componentsInputTextFilled,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (date != null && !w.readOnly)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _ClearButton(
                label: DifyI18n.tr('common', 'operation.clear'),
                visible: _hovered,
                onPressed: () => w.onChange(''),
              ),
            ),
        ],
      ),
    );
  }
}

/// ToolDateRangePicker (DateRangePicker, `clearable`): `flex h-8 rounded-lg bg-components-input-bg-normal px-2`
/// with the calendar icon, the start and end triggers (`h-7 px-1`, "Start date" / "End date") separated by "-", each
/// with its own clear button; the value is the JSON range string ('' when empty).
class ToolDateRangePicker extends StatelessWidget {
  const ToolDateRangePicker({super.key, required this.value, required this.onChange, this.readOnly = false});

  final Object? value;
  final ValueChanged<String> onChange;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final parsed = parseToolDateRangeValue(value);
    void patch({String? start, String? end, bool clearStart = false, bool clearEnd = false}) => onChange(
      stringifyToolDateRangeValue((
        start: clearStart ? null : start ?? parsed.start,
        end: clearEnd ? null : end ?? parsed.end,
      )),
    );
    return Opacity(
      opacity: readOnly ? 0.6 : 1,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          spacing: 2,
          children: [
            Padding(
              padding: EdgeInsets.all(1),
              child: RemixIcon('calendar-line', size: 14, color: DifyColors.textTertiary),
            ),
            Flexible(
              child: _RangeEnd(
                date: parseDateOnly(parsed.start),
                placeholder: DifyI18n.tr('workflow', 'nodes.tool.dateRange.startPlaceholder'),
                readOnly: readOnly,
                onSelect: (d) => patch(start: formatDateOnly(d)),
                onClear: () => patch(clearStart: true),
              ),
            ),
            ExcludeSemantics(
              child: DifyText('-', DifyType.systemSmRegular, color: DifyColors.textTertiary),
            ),
            Flexible(
              child: _RangeEnd(
                date: parseDateOnly(parsed.end),
                placeholder: DifyI18n.tr('workflow', 'nodes.tool.dateRange.endPlaceholder'),
                readOnly: readOnly,
                onSelect: (d) => patch(end: formatDateOnly(d)),
                onClear: () => patch(clearEnd: true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RangeEnd extends StatefulWidget {
  const _RangeEnd({
    required this.date,
    required this.placeholder,
    required this.readOnly,
    required this.onSelect,
    required this.onClear,
  });
  final DateTime? date;
  final String placeholder;
  final bool readOnly;
  final ValueChanged<DateTime> onSelect;
  final VoidCallback onClear;

  @override
  State<_RangeEnd> createState() => _RangeEndState();
}

class _RangeEndState extends State<_RangeEnd> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final shown = _display(w.date);
    final clearable = w.date != null && !w.readOnly;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          _DatePopover(
            selected: w.date,
            onSelect: w.onSelect,
            builder: (context, c) => DifyPressable(
              disabled: w.readOnly,
              onPressed: c.toggle,
              semanticLabel: '${w.placeholder}${shown.isNotEmpty ? ': $shown' : ''}',
              builder: (context, hovered, focused) => Container(
                height: 28,
                padding: EdgeInsets.only(left: 4, right: clearable ? 22 : 4),
                alignment: Alignment.centerLeft,
                decoration: DifyFocusDecoration(
                  color: (hovered && !w.readOnly) || c.isOpen ? DifyColors.stateBaseHover : null,
                  borderRadius: BorderRadius.circular(DifyRadius.lg),
                  boxShadow: difyFocusRing(focused),
                ),
                child: DifyText(
                  shown.isNotEmpty ? shown : w.placeholder,
                  DifyType.systemSmRegular,
                  color: w.date == null
                      ? DifyColors.componentsInputTextPlaceholder
                      : DifyColors.componentsInputTextFilled,
                ),
              ),
            ),
          ),
          if (clearable)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _ClearButton(
                label: '${w.placeholder}: ${DifyI18n.tr('common', 'operation.clear')}',
                visible: _hovered,
                onPressed: w.onClear,
              ),
            ),
        ],
      ),
    );
  }
}
