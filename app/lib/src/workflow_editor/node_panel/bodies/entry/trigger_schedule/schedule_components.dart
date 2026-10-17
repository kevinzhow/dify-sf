/// nodes/trigger-schedule/components: ModeToggle, FrequencySelector, OnMinuteSelector, WeekdaySelector,
/// MonthlyDaysSelector and NextExecutionTimes.
library;

import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../code_editor/editor_view.dart' show codeEditorFontFamily;
import '../../../../panel_fields/panel_fields.dart';
import 'execution_time_calculator.dart';

String _t(String key) => DifyI18n.tr('workflow', 'nodes.triggerSchedule.$key');

/// Tailwind's `text-gray-500` (dify-ui styles.css `--color-gray-500`).
const scheduleGray500 = Color(0xFF667085);

/// The labels above the controls: `mb-2 block text-xs font-medium text-gray-500`.
class ScheduleLabel extends StatelessWidget {
  const ScheduleLabel(this.text, {super.key, this.color = scheduleGray500});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: DifyText(text, DifyType.systemXsMedium, color: color, maxLines: null),
  );
}

/// ModeToggle: `flex items-center gap-1 rounded-lg px-2 py-1 text-sm text-text-secondary hover:bg-state-base-hover`
/// with the Asterisk ("Use cron expression") or CalendarCheckLine ("Use visual picker") icon; a click flips the mode.
class ModeToggle extends StatelessWidget {
  const ModeToggle({super.key, required this.mode, required this.onChange});
  final String mode;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    final visual = mode == 'visual';
    final text = _t(visual ? 'useCronExpression' : 'useVisualPicker');
    return DifyPressable(
      semanticLabel: text,
      onPressed: () => onChange(visual ? 'cron' : 'visual'),
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: hovered ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            DifyIcon(
              visual ? 'vender/workflow/asterisk' : 'vender/workflow/calendar-check-line',
              size: 16,
              color: DifyColors.textSecondary,
            ),
            Text(
              text,
              style: const TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textSecondary, letterSpacing: 0),
            ),
          ],
        ),
      ),
    );
  }
}

/// FrequencySelector: a full-width Select (Hourly / Daily / Weekly / Monthly under the "FREQUENCY" group label),
/// "Select frequency" when nothing matches.
class FrequencySelector extends StatelessWidget {
  const FrequencySelector({super.key, required this.frequency, required this.onChange, this.disabled = false});
  final String frequency;
  final ValueChanged<String> onChange;
  final bool disabled;

  static const values = ['hourly', 'daily', 'weekly', 'monthly'];

  @override
  Widget build(BuildContext context) {
    final options = [for (final v in values) (value: v, label: _t('frequency.$v'))];
    final selected = options.where((o) => o.value == frequency).firstOrNull;
    return LayoutBuilder(
      builder: (context, c) => DifyDropdownMenu(
        placement: DifyPlacement.bottomStart,
        sideOffset: 4,
        width: c.maxWidth.isFinite ? c.maxWidth : null,
        semanticLabel: _t('frequencyLabel'),
        builder: (context, controller) => _SelectTrigger(
          label: _t('frequencyLabel'),
          text: selected?.label ?? _t('selectFrequency'),
          placeholder: selected == null,
          open: controller.isOpen,
          onTap: disabled ? null : controller.toggle,
        ),
        children: [
          DifyMenuGroupLabel(_t('frequency.label')),
          DifyMenuRadioGroup<String>(
            value: frequency,
            onValueChange: onChange,
            children: [
              for (final o in options)
                DifyMenuRadioItem<String>(value: o.value, closeOnClick: true, child: Text(o.label)),
            ],
          ),
        ],
      ),
    );
  }
}

/// dify-ui's SelectTrigger: `h-8 rounded-lg px-3 system-sm-regular` on the input background (hover / open
/// `bg-state-base-hover-alt`) with the chevron.
class _SelectTrigger extends StatefulWidget {
  const _SelectTrigger({
    required this.label,
    required this.text,
    required this.placeholder,
    required this.open,
    this.onTap,
  });
  final String label, text;
  final bool placeholder, open;
  final VoidCallback? onTap;

  @override
  State<_SelectTrigger> createState() => _SelectTriggerState();
}

class _SelectTriggerState extends State<_SelectTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final active = w.onTap != null && (_hovered || w.open);
    return Semantics(
      button: true,
      label: w.label,
      value: w.text,
      expanded: w.open,
      onTap: w.onTap,
      child: MouseRegion(
        cursor: w.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: w.onTap,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: active ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Row(
              spacing: 2,
              children: [
                Expanded(
                  child: DifyText(
                    w.text,
                    DifyType.systemSmRegular,
                    color: w.placeholder
                        ? DifyColors.componentsInputTextPlaceholder
                        : DifyColors.componentsInputTextFilled,
                  ),
                ),
                RemixIcon(
                  'arrow-down-s-line',
                  size: 16,
                  color: active ? DifyColors.textSecondary : DifyColors.textQuaternary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// OnMinuteSelector: "On Minute" over an `h-8 rounded-lg bg-components-input-bg-normal` box holding the value
/// (`w-12 text-[13px]`), a 1 px `bg-components-panel-bg` divider and the 0-59 slider (`pr-3 pl-4`).
class OnMinuteSelector extends StatelessWidget {
  const OnMinuteSelector({super.key, this.value = 0, required this.onChange, this.disabled = false});
  final int value;
  final ValueChanged<int> onChange;
  final bool disabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      ScheduleLabel(_t('onMinute')),
      Container(
        height: 32,
        decoration: BoxDecoration(
          color: DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Center(
                child: Text(
                  '$value',
                  style: const TextStyle(fontSize: 13, color: DifyColors.componentsInputTextFilled, letterSpacing: 0),
                ),
              ),
            ),
            const SizedBox(width: 1, height: 32, child: ColoredBox(color: DifyColors.componentsPanelBg)),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 15, right: 12),
                child: DifySlider(
                  value: value,
                  min: 0,
                  max: 59,
                  semanticLabel: _t('onMinute'),
                  disabled: disabled,
                  onChanged: onChange,
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// The day buttons of both selectors: `rounded-lg border bg-components-option-card-option-bg py-1 text-xs`;
/// selected `border-util-colors-blue-brand-blue-brand-600 text-text-secondary`, else `border-divider-subtle
/// text-text-tertiary` (hover: `border-divider-regular text-text-secondary`).
class _DayButton extends StatelessWidget {
  const _DayButton({required this.label, required this.selected, required this.onTap, this.trailing});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => AnimatedContainer(
      duration: difyTransitionDuration,
      curve: difyTransitionCurve,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: DifyColors.componentsOptionCardOptionBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(
          color: selected
              ? DifyColors.utilColorsBlueBrandBlueBrand600
              : hovered
              ? DifyColors.dividerRegular
              : DifyColors.dividerSubtle,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: DifyText(
              label,
              DifyType.systemXsRegular,
              color: selected || hovered ? DifyColors.textSecondary : DifyColors.textTertiary,
              align: TextAlign.center,
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

/// Fieldset + FieldsetLegend (`mb-2 py-0 text-xs font-medium text-text-tertiary`): a group named by its legend.
class _Fieldset extends StatelessWidget {
  const _Fieldset({required this.legend, required this.children});
  final String legend;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    label: legend,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        ExcludeSemantics(child: DifyText(legend, DifyType.systemXsMedium, color: DifyColors.textTertiary)),
        ...children,
      ],
    ),
  );
}

/// The toggle both selectors share: add or remove [day]; removing the last one keeps it.
List<T> toggleScheduleDay<T>(List<T> current, T day) {
  final next = current.contains(day) ? current.where((d) => d != day).toList() : [...current, day];
  return next.isNotEmpty ? next : [day];
}

/// WeekdaySelector: "Week days" and seven `flex-1` buttons Sun..Sat (Dify's labels are not translated). The
/// selection keeps the click order.
class WeekdaySelector extends StatelessWidget {
  const WeekdaySelector({super.key, required this.selectedDays, required this.onChange});
  final List<String> selectedDays;
  final ValueChanged<List<String>> onChange;

  static const weekdays = [
    ('sun', 'Sun'),
    ('mon', 'Mon'),
    ('tue', 'Tue'),
    ('wed', 'Wed'),
    ('thu', 'Thu'),
    ('fri', 'Fri'),
    ('sat', 'Sat'),
  ];

  @override
  Widget build(BuildContext context) => _Fieldset(
    legend: _t('weekdays'),
    children: [
      Row(
        spacing: 6,
        children: [
          for (final (key, label) in weekdays)
            Expanded(
              child: _DayButton(
                label: label,
                selected: selectedDays.contains(key),
                onTap: () => onChange(toggleScheduleDay(selectedDays, key)),
              ),
            ),
        ],
      ),
    ],
  );
}

/// MonthlyDaysSelector: "Days" and rows of seven (`grid grid-cols-7 gap-1.5`, `space-y-1.5`): 1-28, then 29, 30,
/// 31 and "Last day" (two columns, with its tooltip). With 31 selected the tooltip's text shows below the grid.
class MonthlyDaysSelector extends StatelessWidget {
  const MonthlyDaysSelector({super.key, required this.selectedDays, required this.onChange});
  final List<Object> selectedDays;
  final ValueChanged<List<Object>> onChange;

  @override
  Widget build(BuildContext context) {
    final tip = _t('lastDayTooltip');
    Widget day(Object d) => _DayButton(
      label: d == 'last' ? _t('lastDay') : '$d',
      selected: selectedDays.contains(d),
      onTap: () => onChange(toggleScheduleDay(selectedDays, d)),
      trailing: d == 'last'
          ? Padding(
              padding: const EdgeInsets.only(right: 4),
              child: SizedBox.square(
                dimension: 12,
                child: OverflowBox(
                  maxWidth: 16,
                  maxHeight: 16,
                  child: Infotip(label: tip, iconSize: 12, content: Text(tip)),
                ),
              ),
            )
          : null,
    );
    return _Fieldset(
      legend: _t('days'),
      children: [
        LayoutBuilder(
          builder: (context, c) {
            const gap = 6.0;
            final cell = (c.maxWidth - gap * 6) / 7;
            Widget row(List<Object> days) => Row(
              spacing: gap,
              children: [
                for (final d in days) SizedBox(width: d == 'last' ? cell * 2 + gap : cell, child: day(d)),
              ],
            );
            return Column(
              spacing: gap,
              children: [
                for (var r = 0; r < 4; r++) row([for (var i = 1; i <= 7; i++) r * 7 + i]),
                row(const [29, 30, 31, 'last']),
              ],
            );
          },
        ),
        if (selectedDays.contains(31)) DifyText(tip, DifyType.systemXsRegular, color: scheduleGray500, maxLines: null),
      ],
    );
  }
}

/// NextExecutionTimes: "Next 5 execution times" over a `min-h-20 rounded-xl bg-components-input-bg-normal py-2` box
/// with one row per run: its number (`w-6 text-right`, quaternary) and text, both `font-mono text-xs leading-[150%]
/// tracking-wider`. Nothing when [times] is empty.
class NextExecutionTimes extends StatelessWidget {
  const NextExecutionTimes({super.key, required this.times});
  final List<String> times;

  /// What Dify's NextExecutionTimes shows for [data]: none without a frequency, else the next five runs.
  static List<String> timesOf(Map<String, Object?> data, [ScheduleClock clock = const ScheduleClock()]) {
    final frequency = data['frequency'];
    return frequency is String && frequency.isNotEmpty ? getFormattedExecutionTimes(data, 5, clock) : const [];
  }

  static TextStyle _mono(Color color) => TextStyle(
    fontFamily: codeEditorFontFamily,
    fontFamilyFallback: const ['monospace'],
    fontSize: 12,
    height: 1.5,
    letterSpacing: 0.6,
    color: color,
  );

  @override
  Widget build(BuildContext context) {
    if (times.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        DifyText(_t('nextExecutionTimes'), DifyType.systemXsMedium, color: scheduleGray500, maxLines: null),
        Container(
          constraints: const BoxConstraints(minHeight: 80),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.xl),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, time) in times.indexed)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${i + 1}'.padLeft(2, '0'),
                        textAlign: TextAlign.right,
                        style: _mono(DifyColors.textQuaternary),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8, right: 12),
                        child: Text(time, style: _mono(DifyColors.textSecondary)),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}
