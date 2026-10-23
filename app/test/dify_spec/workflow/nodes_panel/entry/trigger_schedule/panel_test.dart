// dify-spec: web/app/components/workflow/nodes/trigger-schedule/__tests__/panel.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_schedule/schedule_components.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'schedule_harness.dart';

const _p = 'workflow.nodes.triggerSchedule';

Map<String, Object?> _config(Harness h, [String id = 'node-1']) =>
    dataOf(h, id)['visual_config']! as Map<String, Object?>;

Finder _textbox(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is DifyInput && w.semanticLabel == label),
  matching: find.byType(EditableText),
);

void main() {
  setUp(useDifyTestTranslator);

  // Dify mocks useConfig and the leaf controls; here the real ones edit the node, and the checks read its data.
  group('TriggerSchedulePanel', () {
    group('Panel Wiring', () {
      testWidgets('should render the visual controls and forward their callbacks', (t) async {
        final h = await Harness.start(t, [scheduleNode(createScheduleData())]);
        await pumpSchedulePanel(t, h);
        expect(find.text('$_p.nextExecutionTimes'), findsOneWidget);

        await t.tap(find.text('11:30 AM'));
        await t.pumpAndSettle();
        // The lists scroll to the selection (11, 30) as Dify's do; the spec's DOM has no scrolling.
        await tapOption(t, '02');
        await tapOption(t, '45');
        await tapOption(t, 'PM');
        await t.pumpAndSettle();
        await t.tap(find.text('time.operation.ok'));
        await t.pumpAndSettle();
        expect(_config(h)['time'], '2:45 PM');

        await t.tap(find.text('$_p.frequency.daily'));
        await t.pumpAndSettle();
        await t.tap(find.text('$_p.frequency.weekly'));
        await t.pumpAndSettle();
        expect(dataOf(h)['frequency'], 'weekly');
        expect(dataOf(h)['cron_expression'], isNull);

        await t.tap(find.text('$_p.useCronExpression'));
        await t.pumpAndSettle();
        expect(dataOf(h)['mode'], 'cron');
        await h.dispose(t);
      });

      testWidgets('should render weekday and monthly helpers for the matching frequencies', (t) async {
        final h = await Harness.start(t, [
          scheduleNode(createScheduleData({'frequency': 'weekly'})),
          scheduleNode(createScheduleData({'frequency': 'weekly', 'visual_config': null}), id: 'node-5'),
          scheduleNode(createScheduleData({'frequency': 'monthly', 'visual_config': null}), id: 'node-2'),
        ]);
        await pumpSchedulePanel(t, h);
        await t.tap(find.text('Wed'));
        await t.pump();
        expect(_config(h)['weekdays'], ['mon', 'wed']);

        await pumpSchedulePanel(t, h, id: 'node-5');
        await t.tap(find.text('Wed'));
        await t.pump();
        // Without a visual config the defaults (Sunday) are kept and stored.
        expect(_config(h, 'node-5')['weekdays'], ['sun', 'wed']);

        await pumpSchedulePanel(t, h, id: 'node-2');
        expect(find.byType(MonthlyDaysSelector), findsOneWidget);
        await t.tap(find.text('5'));
        await t.pump();
        expect(_config(h, 'node-2')['monthly_days'], [1, 5]);
        await h.dispose(t);
      });

      testWidgets('should render cron mode and forward expression changes', (t) async {
        final h = await Harness.start(t, [
          scheduleNode(createScheduleData({'mode': 'cron', 'frequency': null, 'cron_expression': '0 0 * * *'})),
        ]);
        await pumpSchedulePanel(t, h);
        await t.enterText(_textbox('$_p.cronExpression'), '*/5 * * * *');
        await t.pump();
        final data = dataOf(h);
        expect(data['cron_expression'], '*/5 * * * *');
        expect(data['frequency'], isNull);
        expect(data['visual_config'], isNull);
        await h.dispose(t);
      });

      testWidgets('should use daily and empty cron defaults when the schedule values are missing', (t) async {
        final h = await Harness.start(t, [
          scheduleNode(createScheduleData({'frequency': null})),
          scheduleNode(createScheduleData({'mode': 'cron', 'frequency': null, 'cron_expression': null}), id: 'node-7'),
        ]);
        await pumpSchedulePanel(t, h);
        expect(find.text('$_p.frequency.daily'), findsOneWidget);
        expect(find.text('11:30 AM'), findsOneWidget);

        await pumpSchedulePanel(t, h, id: 'node-7');
        expect(t.widget<EditableText>(_textbox('$_p.cronExpression')).controller.text, '');
        await h.dispose(t);
      });

      testWidgets('should render the hourly minute selector when the frequency is hourly', (t) async {
        final h = await Harness.start(t, [
          scheduleNode(createScheduleData({'frequency': 'hourly'})),
        ]);
        await pumpSchedulePanel(t, h);
        expect(find.byType(OnMinuteSelector), findsOneWidget);
        await t.tap(find.byType(DifySlider));
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.home);
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pump();
        expect(_config(h)['on_minute'], 1);
        expect(find.text('1'), findsOneWidget);
        await h.dispose(t);
      });
    });
  });

  group('read-only panel', () {
    testWidgets('drops edits like useNodeCrud does', (t) async {
      final h = await Harness.start(t, [scheduleNode(createScheduleData())]);
      h.store.setCanvasReadOnly(true);
      await pumpSchedulePanel(t, h);
      await t.tap(find.text('$_p.useCronExpression'));
      await t.pump();
      expect(dataOf(h)['mode'], 'visual');
      expect(find.byType(DifyPopover), findsOneWidget);
      await h.dispose(t);
    });
  });
}
