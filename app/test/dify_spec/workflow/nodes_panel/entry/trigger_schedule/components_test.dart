// dify-spec: web/app/components/workflow/nodes/trigger-schedule/components/__tests__/frequency-selector.spec.tsx
// dify-spec: web/app/components/workflow/nodes/trigger-schedule/components/__tests__/integration.spec.tsx
// dify-spec: web/app/components/workflow/nodes/trigger-schedule/components/__tests__/mode-toggle.spec.tsx
// dify-spec: web/app/components/workflow/nodes/trigger-schedule/components/__tests__/monthly-days-selector.spec.tsx
// dify-spec: web/app/components/workflow/nodes/trigger-schedule/components/__tests__/next-execution-times.spec.tsx
// dify-spec: web/app/components/workflow/nodes/trigger-schedule/components/__tests__/on-minute-selector.spec.tsx
// dify-spec: web/app/components/workflow/nodes/trigger-schedule/components/__tests__/weekday-selector.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_schedule/schedule_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'schedule_harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const _p = 'workflow.nodes.triggerSchedule';

Future<void> render(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1400, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 1000, child: child),
        ),
      ),
    ),
  );
}

/// `vi.fn()`: the calls of a one-argument callback.
class Calls<T> {
  final values = <T>[];
  void call(T v) => values.add(v);
}

Future<void> openAndPickWeekly(WidgetTester t) async {
  await t.tap(find.text('$_p.frequency.daily'));
  await t.pumpAndSettle();
  await t.tap(find.text('$_p.frequency.weekly'));
  await t.pumpAndSettle();
}

/// Focuses the slider and presses the right arrow.
Future<void> stepSliderRight(WidgetTester t) async {
  final inside = t.element(find.descendant(of: find.byType(DifySlider), matching: find.byType(MouseRegion)).first);
  Focus.of(inside).requestFocus();
  await t.pump();
  await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
  await t.pump();
}

void main() {
  setUp(useDifyTestTranslator);

  group('trigger-schedule/frequency-selector', () {
    testWidgets('selects a new frequency from the dropdown options', (t) async {
      final onChange = Calls<String>();
      await render(t, FrequencySelector(frequency: 'daily', onChange: onChange.call));
      await t.tap(find.text('$_p.frequency.daily'));
      await t.pumpAndSettle();
      expect(find.text('$_p.frequency.label'.toUpperCase()), findsOneWidget);
      await t.tap(find.text('$_p.frequency.weekly'));
      await t.pumpAndSettle();
      expect(onChange.values, ['weekly']);
    });
  });

  group('trigger-schedule components', () {
    group('Leaf Rendering', () {
      testWidgets('should toggle the mode from visual to cron', (t) async {
        final onChange = Calls<String>();
        await render(t, ModeToggle(mode: 'visual', onChange: onChange.call));
        await t.tap(find.byType(ModeToggle));
        expect(onChange.values, ['cron']);
      });

      testWidgets('should toggle the mode from cron back to visual', (t) async {
        final onChange = Calls<String>();
        await render(t, ModeToggle(mode: 'cron', onChange: onChange.call));
        await t.tap(find.byType(ModeToggle));
        expect(onChange.values, ['visual']);
      });

      testWidgets('should change the hourly minute through the slider', (t) async {
        final onChange = Calls<int>();
        await render(t, OnMinuteSelector(value: 15, onChange: onChange.call));
        await stepSliderRight(t);
        expect(onChange.values, [16]);
      });

      testWidgets('should keep at least one weekday selected', (t) async {
        final onChange = Calls<List<String>>();
        await render(t, WeekdaySelector(selectedDays: const ['mon'], onChange: onChange.call));
        await t.tap(find.text('Mon'));
        expect(onChange.values, [
          ['mon'],
        ]);
      });

      testWidgets('should add a new weekday when the day is not selected yet', (t) async {
        final onChange = Calls<List<String>>();
        await render(t, WeekdaySelector(selectedDays: const [], onChange: onChange.call));
        await t.tap(find.text('Tue'));
        expect(onChange.values, [
          ['tue'],
        ]);
      });

      testWidgets('should toggle monthly days and show the day-31 warning', (t) async {
        final onChange = Calls<List<Object>>();
        await render(t, MonthlyDaysSelector(selectedDays: const [31], onChange: onChange.call));
        expect(find.text('$_p.lastDayTooltip'), findsOneWidget);
        await t.tap(find.text('$_p.lastDay'));
        expect(onChange.values, isNotEmpty);
      });

      testWidgets('should render the upcoming execution times when the schedule is valid', (t) async {
        await render(t, NextExecutionTimes(times: NextExecutionTimes.timesOf(createScheduleData())));
        expect(find.text('$_p.nextExecutionTimes'), findsOneWidget);
        expect(find.textContaining(RegExp(r'^\d{2}$')), findsWidgets);
      });

      testWidgets('should hide upcoming execution times when frequency is missing or cron is invalid', (t) async {
        await render(t, NextExecutionTimes(times: NextExecutionTimes.timesOf(createScheduleData({'frequency': null}))));
        expect(find.byType(Text), findsNothing);
        await render(
          t,
          NextExecutionTimes(
            times: NextExecutionTimes.timesOf(createScheduleData({'mode': 'cron', 'cron_expression': 'bad cron'})),
          ),
        );
        expect(find.byType(Text), findsNothing);
      });
    });
  });

  group('trigger-schedule/mode-toggle', () {
    testWidgets('toggles the mode from visual to cron', (t) async {
      final onChange = Calls<String>();
      await render(t, ModeToggle(mode: 'visual', onChange: onChange.call));
      expect(find.text('$_p.useCronExpression'), findsOneWidget);
      await t.tap(find.byType(ModeToggle));
      expect(onChange.values, ['cron']);
    });

    testWidgets('toggles the mode from cron back to visual', (t) async {
      final onChange = Calls<String>();
      await render(t, ModeToggle(mode: 'cron', onChange: onChange.call));
      expect(find.text('$_p.useVisualPicker'), findsOneWidget);
      await t.tap(find.byType(ModeToggle));
      expect(onChange.values, ['visual']);
    });
  });

  group('trigger-schedule/monthly-days-selector', () {
    testWidgets('names the monthly day selection group', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, MonthlyDaysSelector(selectedDays: const [1], onChange: (_) {}));
      expect(find.bySemanticsLabel('$_p.days'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('toggles monthly days and shows the day-31 warning', (t) async {
      final onChange = Calls<List<Object>>();
      await render(t, MonthlyDaysSelector(selectedDays: const [31], onChange: onChange.call));
      expect(find.text('$_p.lastDayTooltip'), findsOneWidget);
      await t.tap(find.text('$_p.lastDay'));
      expect(onChange.values, [
        [31, 'last'],
      ]);
    });

    testWidgets('keeps the clicked day selected when removing the last selected day', (t) async {
      final onChange = Calls<List<Object>>();
      await render(t, MonthlyDaysSelector(selectedDays: const [31], onChange: onChange.call));
      await t.tap(find.text('31'));
      expect(onChange.values, [
        [31],
      ]);
    });
  });

  group('trigger-schedule/next-execution-times', () {
    testWidgets('renders the upcoming execution times when the schedule is valid', (t) async {
      await render(t, NextExecutionTimes(times: NextExecutionTimes.timesOf(createScheduleData())));
      expect(find.text('$_p.nextExecutionTimes'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\d{2}$')), findsNWidgets(5));
    });

    testWidgets('hides upcoming execution times when frequency is missing or cron is invalid', (t) async {
      await render(t, NextExecutionTimes(times: NextExecutionTimes.timesOf(createScheduleData({'frequency': null}))));
      expect(find.byType(Text), findsNothing);
      await render(
        t,
        NextExecutionTimes(
          times: NextExecutionTimes.timesOf(createScheduleData({'mode': 'cron', 'cron_expression': 'bad cron'})),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });
  });

  group('trigger-schedule/on-minute-selector', () {
    testWidgets('changes the hourly minute through the slider', (t) async {
      final semantics = t.ensureSemantics();
      final onChange = Calls<int>();
      await render(t, OnMinuteSelector(value: 15, onChange: onChange.call));
      expect(find.bySemanticsLabel('$_p.onMinute'), findsWidgets);
      await stepSliderRight(t);
      expect(onChange.values, [16]);
      semantics.dispose();
    });
  });

  group('trigger-schedule/weekday-selector', () {
    testWidgets('names the weekday selection group', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, WeekdaySelector(selectedDays: const ['mon'], onChange: (_) {}));
      expect(find.bySemanticsLabel('$_p.weekdays'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('keeps at least one weekday selected', (t) async {
      final onChange = Calls<List<String>>();
      await render(t, WeekdaySelector(selectedDays: const ['mon'], onChange: onChange.call));
      await t.tap(find.text('Mon'));
      expect(onChange.values, [
        ['mon'],
      ]);
    });

    testWidgets('adds a new weekday when the day is not selected yet', (t) async {
      final onChange = Calls<List<String>>();
      await render(t, WeekdaySelector(selectedDays: const [], onChange: onChange.call));
      await t.tap(find.text('Tue'));
      expect(onChange.values, [
        ['tue'],
      ]);
    });
  });
}
