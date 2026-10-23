// dify-spec: web/app/components/workflow/nodes/trigger-schedule/__tests__/use-config.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_schedule/execution_time_calculator.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_schedule/schedule_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'schedule_harness.dart';

/// `withSelectorKey`-style translation: the key with its parameters.
String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
    params.isEmpty ? key : '$key:${params.values.join(',')}';

void main() {
  // useConfig is ported as scheduleInputs (its frontend payload) and the handlers returning what setInputs writes.
  group('trigger-schedule/use-config', () {
    test('hydrates defaults for missing mode, frequency, timezone, and visual config', () {
      final inputs = scheduleInputs(
        createScheduleData({'mode': null, 'frequency': null, 'timezone': null, 'visual_config': null}),
        profileTimezone: 'Asia/Shanghai',
      );
      expect(inputs, containsPair('mode', 'visual'));
      expect(inputs, containsPair('frequency', 'daily'));
      expect(inputs, containsPair('timezone', 'Asia/Shanghai'));
      expect(inputs['visual_config'], {
        'time': '12:00 AM',
        'weekdays': ['sun'],
        'on_minute': 0,
        'monthly_days': [1],
      });
    });

    test('updates visual mode configuration and clears cron expression when needed', () {
      final inputs = scheduleInputs(createScheduleData({'cron_expression': '0 0 * * *'}));
      expect(handleModeChange(inputs, 'cron'), containsPair('mode', 'cron'));

      final hourly = handleFrequencyChange(inputs, 'hourly');
      expect(hourly['frequency'], 'hourly');
      expect(hourly['cron_expression'], isNull);
      expect(hourly['visual_config'], containsPair('on_minute', 15));

      final weekdays = handleWeekdaysChange(inputs, ['tue', 'thu']);
      expect(weekdays['visual_config'], containsPair('weekdays', ['tue', 'thu']));
      expect(weekdays['cron_expression'], isNull);

      final time = handleTimeChange(inputs, '08:15 AM');
      expect(time['visual_config'], containsPair('time', '08:15 AM'));
      expect(time['cron_expression'], isNull);

      final minute = handleOnMinuteChange(inputs, 45);
      expect(minute['visual_config'], containsPair('on_minute', 45));
      expect(minute['cron_expression'], isNull);
    });

    test('switches to raw cron mode and clears visual schedule fields', () {
      final next = handleCronExpressionChange(scheduleInputs(createScheduleData()), '*/15 * * * *');
      expect(next['cron_expression'], '*/15 * * * *');
      expect(next['frequency'], isNull);
      expect(next['visual_config'], isNull);
    });
  });

  // default.ts checkValid (no Dify spec): the messages in order.
  group('checkValidTriggerSchedule', () {
    final clock = ScheduleClock(now: () => DateTime.utc(2024, 1, 15, 10));
    String check(Map<String, Object?> data) => checkValidTriggerSchedule(data, t, null, clock: clock);

    test('accepts the default value and the spec data', () {
      expect(check(triggerScheduleDefaultValue()), '');
      expect(check(createScheduleData()), '');
      expect(check(createScheduleData({'mode': 'cron', 'cron_expression': '@daily'})), '');
    });

    test('reports the first problem', () {
      expect(check(createScheduleData({'mode': null})), 'errorMsg.fieldRequired:nodes.triggerSchedule.mode');
      expect(check(createScheduleData({'timezone': 'Mars/Olympus'})), 'nodes.triggerSchedule.invalidTimezone');
      expect(
        check(createScheduleData({'mode': 'cron', 'cron_expression': ' '})),
        'errorMsg.fieldRequired:nodes.triggerSchedule.cronExpression',
      );
      expect(
        check(createScheduleData({'mode': 'cron', 'cron_expression': '61 * * * *'})),
        'nodes.triggerSchedule.invalidCronExpression',
      );
      expect(
        check(createScheduleData({'frequency': null})),
        'errorMsg.fieldRequired:nodes.triggerSchedule.frequencyLabel',
      );
      expect(
        check(createScheduleData({'visual_config': null})),
        'errorMsg.fieldRequired:nodes.triggerSchedule.visualConfig',
      );
      expect(
        check(
          createScheduleData({
            'frequency': 'hourly',
            'visual_config': {'on_minute': 60},
          }),
        ),
        'nodes.triggerSchedule.invalidOnMinute',
      );
      expect(
        check(
          createScheduleData({
            'visual_config': {'time': '13:00 PM'},
          }),
        ),
        'nodes.triggerSchedule.invalidTimeFormat',
      );
      expect(
        check(
          createScheduleData({
            'frequency': 'weekly',
            'visual_config': {
              'time': '1:00 AM',
              'weekdays': ['fun'],
            },
          }),
        ),
        'nodes.triggerSchedule.invalidWeekday:fun',
      );
      expect(
        check(
          createScheduleData({
            'frequency': 'monthly',
            'visual_config': {'time': '1:00 AM', 'monthly_days': []},
          }),
        ),
        'errorMsg.fieldRequired:nodes.triggerSchedule.monthlyDay',
      );
      expect(
        check(
          createScheduleData({
            'frequency': 'monthly',
            'visual_config': {
              'time': '1:00 AM',
              'monthly_days': [32],
            },
          }),
        ),
        'nodes.triggerSchedule.invalidMonthlyDay',
      );
      expect(check(createScheduleData({'frequency': 'yearly'})), 'nodes.triggerSchedule.invalidFrequency');
      expect(
        check(
          createScheduleData({
            'frequency': 'weekly',
            'visual_config': {'time': '1:00 AM', 'weekdays': []},
          }),
        ),
        'errorMsg.fieldRequired:nodes.triggerSchedule.weekdays',
      );
    });
  });
}
