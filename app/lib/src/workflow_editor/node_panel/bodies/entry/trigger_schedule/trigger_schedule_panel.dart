/// The Schedule Trigger's panel body (nodes/trigger-schedule/panel.tsx): the "Schedule" field with the mode toggle,
/// the visual picker (frequency, time or minute, week days, month days) or the cron expression, then the next five
/// runs. No output variables.
library;

import 'package:flutter/widgets.dart';

import '../../../../../design/dify_tokens.g.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../code_editor/editor_view.dart' show codeEditorFontFamily;
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../../../panel_edit.dart';
import 'schedule_components.dart';
import 'schedule_config.dart';
import 'schedule_host.dart';
import 'schedule_timezone.dart';
import 'time_picker.dart';

export 'cron_parser.dart' show isValidCronExpression, parseCronExpression;
export 'execution_time_calculator.dart' show ScheduleClock, getNextExecutionTime, getNextExecutionTimes;
export 'schedule_config.dart' show checkValidTriggerSchedule, triggerScheduleDefaultValue;
export 'schedule_host.dart';

String _t(String key) => DifyI18n.tr('workflow', 'nodes.triggerSchedule.$key');

/// The body of `trigger-schedule` nodes.
Widget triggerSchedulePanelBody(BuildContext context, NodePanelProps props) =>
    TriggerSchedulePanel(key: ValueKey('trigger-schedule-${props.id}'), props: props);

class TriggerSchedulePanel extends StatefulWidget {
  const TriggerSchedulePanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<TriggerSchedulePanel> createState() => _TriggerSchedulePanelState();
}

class _TriggerSchedulePanelState extends State<TriggerSchedulePanel> {
  final _cronFocus = FocusNode(debugLabel: 'cron expression');

  /// The document version the cron expression's draft began on (its first keystroke since it got the focus).
  int? _cronBase;

  @override
  void initState() {
    super.initState();
    _cronFocus.addListener(() {
      if (!_cronFocus.hasFocus) _cronBase = null;
    });
  }

  @override
  void dispose() {
    _cronFocus.dispose();
    super.dispose();
  }

  NodePanelProps get props => widget.props;

  /// useNodeCrud's setInputs: Dify drops edits while the nodes are read-only.
  void _set(Map<String, Object?> next) {
    if (!props.readOnly) setInputs(props, next);
  }

  void _cron(Map<String, Object?> inputs, String value) {
    if (props.readOnly) return;
    final base = _cronBase ??= props.controller.seenVersion;
    // The other keys handleCronExpressionChange clears go as usual; the typed text carries its draft's version.
    _set({...handleCronExpressionChange(inputs, value), 'cron_expression': inputs['cron_expression']});
    props.setData('cron_expression', value, base: base);
  }

  @override
  Widget build(BuildContext context) {
    final host = ScheduleHost.of(context);
    final inputs = scheduleInputs(props.data, profileTimezone: host.profileTimezone);
    final config = inputs['visual_config'] is Map<String, Object?>
        ? inputs['visual_config']! as Map<String, Object?>
        : const <String, Object?>{};
    final timezone = inputs['timezone'] as String;
    final mode = inputs['mode'];
    final frequency = inputs['frequency'];
    final times = NextExecutionTimes.timesOf(inputs, host.clock);

    Widget visual() {
      final time = config['time'] is String && (config['time']! as String).isNotEmpty
          ? config['time']! as String
          : '12:00 AM';
      final second = frequency == 'hourly'
          ? OnMinuteSelector(
              value: switch (config['on_minute']) {
                final num n => n.toInt(),
                _ => 0,
              },
              onChange: (m) => _set(handleOnMinuteChange(inputs, m)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                ScheduleLabel(_t('time')),
                TimePicker(
                  notClearable: true,
                  timezone: timezone,
                  value: time,
                  triggerFullWidth: true,
                  showTimezone: true,
                  placeholder: _t('selectTime'),
                  now: () => wallClockAt(timezone, host.clock.instant(), offset: host.clock.offset),
                  onChange: (t) {
                    if (t != null) _set(handleTimeChange(inputs, formatTimeHMmA(t)));
                  },
                  onClear: () => _set(handleTimeChange(inputs, '12:00 AM')),
                ),
              ],
            );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final col = (c.maxWidth - 24) / 3;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: col,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ScheduleLabel(_t('frequencyLabel')),
                        FrequencySelector(
                          frequency: jsTruthyString(frequency) ? frequency! as String : 'daily',
                          onChange: (f) => _set(handleFrequencyChange(inputs, f)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: second),
                ],
              );
            },
          ),
          if (frequency == 'weekly')
            WeekdaySelector(
              selectedDays: [
                for (final d in config['weekdays'] is List ? config['weekdays']! as List : const [])
                  ?(d is String ? d : null),
              ],
              onChange: (days) => _set(handleWeekdaysChange(inputs, days)),
            ),
          if (frequency == 'monthly')
            MonthlyDaysSelector(
              selectedDays: _monthlyDays(config['monthly_days']),
              onChange: (days) => _set(handleMonthlyDaysChange(inputs, days)),
            ),
        ],
      );
    }

    Widget cron() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ScheduleLabel(_t('cronExpression')),
        DifyInput(
          value: inputs['cron_expression'] is String ? inputs['cron_expression']! as String : '',
          placeholder: '0 0 * * *',
          fontFamily: codeEditorFontFamily, // font-mono
          semanticLabel: _t('cronExpression'),
          focusNode: _cronFocus,
          onChanged: (v) => _cron(inputs, v),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          Field(
            title: _t('title'),
            operations: ModeToggle(
              mode: mode is String ? mode : 'visual',
              onChange: (m) => _set(handleModeChange(inputs, m)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                if (mode == 'visual') visual(),
                if (mode == 'cron') cron(),
              ],
            ),
          ),
          SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
          if (times.isNotEmpty) NextExecutionTimes(times: times),
        ],
      ),
    );
  }
}

/// `visual_config.monthly_days || [1]`, as numbers and 'last'.
List<Object> _monthlyDays(Object? v) {
  if (v is! List) return const [1];
  return [
    for (final d in v)
      if (d is num) d.toInt() else if (d == 'last') 'last',
  ];
}

/// JavaScript truthiness of a string field.
bool jsTruthyString(Object? v) => v is String && v.isNotEmpty;
