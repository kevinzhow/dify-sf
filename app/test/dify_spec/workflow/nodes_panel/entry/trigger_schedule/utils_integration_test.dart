// dify-spec: web/app/components/workflow/nodes/trigger-schedule/utils/__tests__/integration.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_schedule/cron_parser.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_schedule/execution_time_calculator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // vi.setSystemTime(new Date('2024-01-15T10:00:00Z'))
  var systemTime = DateTime.utc(2024, 1, 15, 10);
  final clock = ScheduleClock(now: () => systemTime);

  Map<String, Object?> createCronData([Map<String, Object?> overrides = const {}]) => {
    'type': 'trigger-schedule',
    'title': 'test-schedule',
    'mode': 'cron',
    'frequency': 'daily',
    'timezone': 'UTC',
    ...overrides,
  };

  List<DateTime> parse(String expression, String timezone) =>
      parseCronExpression(expression, timezone, systemTime, clock.offset);

  group('cron-parser + execution-time-calculator integration', () {
    group('backward compatibility validation', () {
      test('maintains exact behavior for legacy cron expressions', () {
        const legacyExpressions = [
          '15 10 1 * *',
          '0 0 * * 0',
          '*/5 * * * *',
          '0 9-17 * * 1-5',
          '30 14 * * 1',
          '0 0 1,15 * *',
        ];
        for (final expression in legacyExpressions) {
          final directResult = parse(expression, 'UTC');
          expect(directResult, hasLength(5));
          expect(isValidCronExpression(expression), isTrue);

          final calculatorResult = getNextExecutionTimes(createCronData({'cron_expression': expression}), 5, clock);
          expect(calculatorResult, hasLength(5));
          for (final (index, directDate) in directResult.indexed) {
            final calcDate = calculatorResult[index];
            expect(calcDate, directDate);
            expect(calcDate.hour, directDate.hour);
            expect(calcDate.minute, directDate.minute);
          }
        }
      });

      test('validates timezone handling consistency', () {
        const timezones = ['UTC', 'America/New_York', 'Asia/Tokyo', 'Europe/London'];
        const expression = '0 12 * * *';
        for (final timezone in timezones) {
          final directResult = parse(expression, timezone);
          final calculatorResult = getNextExecutionTimes(
            createCronData({'cron_expression': expression, 'timezone': timezone}),
            5,
            clock,
          );
          expect(directResult, hasLength(5));
          expect(calculatorResult, hasLength(5));
          for (final date in directResult) {
            expect(date.hour, 12);
          }
          for (final date in calculatorResult) {
            expect(date.hour, 12);
          }
          for (final (index, directDate) in directResult.indexed) {
            expect(calculatorResult[index], directDate);
          }
        }
      });

      test('error handling consistency', () {
        const invalidExpressions = [
          '',
          '   ',
          '60 10 1 * *',
          '15 25 1 * *',
          '15 10 32 * *',
          '15 10 1 13 *',
          '15 10 1',
          '15 10 1 * * *',
          'invalid expression',
        ];
        for (final expression in invalidExpressions) {
          expect(isValidCronExpression(expression), isFalse, reason: expression);
          expect(parse(expression, 'UTC'), isEmpty);
          final data = createCronData({'cron_expression': expression});
          expect(getNextExecutionTimes(data, 5, clock), isEmpty);
          expect(getNextExecutionTime(data, clock), '--');
        }
      });
    });

    group('enhanced features integration', () {
      test('month and day abbreviations work end-to-end', () {
        final enhancedExpressions = <({String expr, Object? month, int? day, int? weekday, int hour, int minute})>[
          (expr: '0 9 1 JAN *', month: 0, day: 1, weekday: null, hour: 9, minute: 0),
          (expr: '0 15 * * MON', month: null, day: null, weekday: 1, hour: 15, minute: 0),
          (expr: '30 10 15 JUN,DEC *', month: [5, 11], day: 15, weekday: null, hour: 10, minute: 30),
          (expr: '0 12 * JAN-MAR *', month: [0, 1, 2], day: null, weekday: null, hour: 12, minute: 0),
        ];
        for (final e in enhancedExpressions) {
          expect(isValidCronExpression(e.expr), isTrue);
          final directResult = parse(e.expr, 'UTC');
          final calculatorResult = getNextExecutionTimes(createCronData({'cron_expression': e.expr}), 3, clock);
          expect(directResult, isNotEmpty);
          expect(calculatorResult, isNotEmpty);
          void validateDate(DateTime date) {
            expect(date.hour, e.hour);
            expect(date.minute, e.minute);
            // JavaScript months count from 0.
            if (e.month case final List<int> months) {
              expect(months, contains(date.month - 1));
            } else if (e.month case final int month) {
              expect(date.month - 1, month);
            }
            if (e.day != null) expect(date.day, e.day);
            if (e.weekday != null) expect(date.weekday % 7, e.weekday);
          }

          directResult.forEach(validateDate);
          calculatorResult.forEach(validateDate);
        }
      });

      test('predefined expressions work through execution-time-calculator', () {
        final predefExpressions = <({String expr, int hour, int minute, int? weekday, int? day, int? month})>[
          (expr: '@daily', hour: 0, minute: 0, weekday: null, day: null, month: null),
          (expr: '@weekly', hour: 0, minute: 0, weekday: 0, day: null, month: null),
          (expr: '@monthly', hour: 0, minute: 0, weekday: null, day: 1, month: null),
          (expr: '@yearly', hour: 0, minute: 0, weekday: null, day: 1, month: 0),
        ];
        for (final e in predefExpressions) {
          expect(isValidCronExpression(e.expr), isTrue);
          final result = getNextExecutionTimes(createCronData({'cron_expression': e.expr}), 3, clock);
          expect(result, isNotEmpty);
          for (final date in result) {
            expect(date.hour, e.hour);
            expect(date.minute, e.minute);
            if (e.weekday != null) expect(date.weekday % 7, e.weekday);
            if (e.day != null) expect(date.day, e.day);
            if (e.month != null) expect(date.month - 1, e.month);
          }
        }
      });

      test('special characters integration', () {
        const specialExpressions = ['0 9 ? * 1', '0 12 * * 7', '0 15 L * *'];
        for (final expr in specialExpressions) {
          expect(isValidCronExpression(expr), isTrue);
          final directResult = parse(expr, 'UTC');
          final calculatorResult = getNextExecutionTimes(createCronData({'cron_expression': expr}), 2, clock);
          expect(directResult, isNotEmpty);
          expect(calculatorResult, isNotEmpty);
          expect(calculatorResult[0].hour, directResult[0].hour);
          expect(calculatorResult[0].minute, directResult[0].minute);
        }
      });
    });

    group('DST and timezone edge cases', () {
      test('handles DST transitions consistently', () {
        systemTime = DateTime.utc(2024, 3, 8, 10);
        addTearDown(() => systemTime = DateTime.utc(2024, 1, 15, 10));
        const expression = '0 2 * * *';
        const timezone = 'America/New_York';
        final directResult = parse(expression, timezone);
        final calculatorResult = getNextExecutionTimes(
          createCronData({'cron_expression': expression, 'timezone': timezone}),
          5,
          clock,
        );
        expect(directResult, isNotEmpty);
        expect(calculatorResult, isNotEmpty);
        for (final date in directResult) {
          expect([2, 3], contains(date.hour));
        }
        for (final date in calculatorResult) {
          expect([2, 3], contains(date.hour));
        }
        for (final (index, directDate) in directResult.indexed) {
          expect(calculatorResult[index], directDate);
        }
      });

      test('complex timezone scenarios', () {
        const scenarios = [
          (tz: 'Asia/Kolkata', expr: '30 14 * * *', expectedHour: 14, expectedMinute: 30),
          (tz: 'Australia/Adelaide', expr: '0 8 * * *', expectedHour: 8, expectedMinute: 0),
          (tz: 'Pacific/Kiritimati', expr: '0 12 * * *', expectedHour: 12, expectedMinute: 0),
        ];
        for (final s in scenarios) {
          final directResult = parse(s.expr, s.tz);
          final calculatorResult = getNextExecutionTimes(
            createCronData({'cron_expression': s.expr, 'timezone': s.tz}),
            2,
            clock,
          );
          expect(directResult, isNotEmpty);
          expect(calculatorResult, isNotEmpty);
          for (final date in [...directResult, ...calculatorResult]) {
            expect(date.hour, s.expectedHour);
            expect(date.minute, s.expectedMinute);
          }
          expect(calculatorResult[0], directResult[0]);
        }
      });
    });

    group('performance and reliability', () {
      test('handles high-frequency expressions efficiently', () {
        const highFreqExpressions = ['*/1 * * * *', '*/5 * * * *', '0,15,30,45 * * * *'];
        for (final expr in highFreqExpressions) {
          final watch = Stopwatch()..start();
          final directResult = parse(expr, 'UTC');
          final calculatorResult = getNextExecutionTimes(createCronData({'cron_expression': expr}), 5, clock);
          watch.stop();
          expect(directResult, hasLength(5));
          expect(calculatorResult, hasLength(5));
          expect(watch.elapsedMilliseconds, lessThan(100));
          for (final (index, directDate) in directResult.indexed) {
            expect(calculatorResult[index], directDate);
          }
        }
      });

      test('stress test with complex expressions', () {
        const complexExpressions = ['15,45 8-18 1,15 JAN-MAR MON-FRI', '0 */2 ? * SUN#1,SUN#3', '30 9 L * *'];
        for (final expr in complexExpressions) {
          if (!isValidCronExpression(expr)) continue;
          final directResult = parse(expr, 'America/New_York');
          final calculatorResult = getNextExecutionTimes(
            createCronData({'cron_expression': expr, 'timezone': 'America/New_York'}),
            3,
            clock,
          );
          expect(directResult, isNotEmpty);
          expect(calculatorResult, isNotEmpty);
          final minLength = directResult.length < calculatorResult.length
              ? directResult.length
              : calculatorResult.length;
          for (var i = 0; i < minLength; i++) {
            expect(calculatorResult[i], directResult[i]);
          }
        }
      });
    });

    group('format compatibility', () {
      test('getNextExecutionTime formatting consistency', () {
        const testCases = [
          (expr: '0 9 * * *', timezone: 'UTC'),
          (expr: '30 14 * * 1-5', timezone: 'America/New_York'),
          (expr: '@daily', timezone: 'Asia/Tokyo'),
        ];
        for (final c in testCases) {
          final timeString = getNextExecutionTime(
            createCronData({'cron_expression': c.expr, 'timezone': c.timezone}),
            clock,
          );
          expect(timeString, isNot('--'));
          expect(timeString, isNotEmpty);
          expect(timeString, matches(RegExp(r'\d+:\d+')));
          expect(timeString, matches(RegExp('AM|PM')));
          expect(timeString, matches(RegExp(r'\d{4}')));
        }
      });
    });
  });

  // Beyond Dify's cases: the visual calculations and the texts against fixed times.
  group('visual schedules', () {
    final noon = ScheduleClock(now: () => DateTime.utc(2024, 1, 15, 12, 30)); // a Monday
    Map<String, Object?> visual(String frequency, Map<String, Object?> config, [String timezone = 'UTC']) => {
      'mode': 'visual',
      'frequency': frequency,
      'timezone': timezone,
      'visual_config': config,
    };

    test('hourly starts with the next hour once the minute passed', () {
      expect(getNextExecutionTimes(visual('hourly', {'on_minute': 15}), 2, noon), [
        DateTime.utc(2024, 1, 15, 13, 15),
        DateTime.utc(2024, 1, 15, 14, 15),
      ]);
      expect(getNextExecutionTimes(visual('hourly', {'on_minute': 45}), 1, noon), [DateTime.utc(2024, 1, 15, 12, 45)]);
    });

    test('daily, weekly and monthly runs in the timezone', () {
      expect(getNextExecutionTimes(visual('daily', {'time': '11:30 AM'}), 1, noon), [
        DateTime.utc(2024, 1, 16, 11, 30),
      ]);
      // 12:30 UTC is 20:30 in Shanghai.
      expect(getNextExecutionTimes(visual('daily', {'time': '9:00 PM'}, 'Asia/Shanghai'), 1, noon), [
        DateTime.utc(2024, 1, 15, 21),
      ]);
      expect(
        getNextExecutionTimes(
          visual('weekly', {
            'time': '12:00 AM',
            'weekdays': ['wed', 'mon'],
          }),
          3,
          noon,
        ),
        [
          DateTime.utc(2024, 1, 17),
          DateTime.utc(2024, 1, 22),
          DateTime.utc(2024, 1, 24),
        ],
      );
      expect(
        getNextExecutionTimes(
          visual('monthly', {
            'time': '12:00 AM',
            'monthly_days': [31, 'last'],
          }),
          3,
          noon,
        ),
        [
          DateTime.utc(2024, 1, 31),
          DateTime.utc(2024, 2, 29),
          DateTime.utc(2024, 3, 31),
        ],
      );
    });

    test('formats like en-US with the offset in the panel', () {
      final data = visual('weekly', {
        'time': '9:05 PM',
        'weekdays': ['mon'],
      }, 'Asia/Kolkata');
      expect(getFormattedExecutionTimes(data, 1, noon), ['Monday, January 15, 2024, 9:05 PM (UTC+5:30)']);
      expect(getNextExecutionTime(data, noon), 'Monday, January 15, 2024, 9:05 PM');
    });
  });
}
