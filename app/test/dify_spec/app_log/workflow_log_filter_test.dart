// dify-spec: web/app/components/app/workflow-log/__tests__/filter.spec.tsx
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/app_detail/logs/workflow_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

WorkflowLogFilterQuery q({String status = 'all', String period = '2', String? keyword}) =>
    WorkflowLogFilterQuery(status: status, period: period, keyword: keyword);

void main() {
  late List<WorkflowLogFilterQuery> calls;
  setUp(() => calls = []);

  Future<void> renderFilter(WidgetTester t, WorkflowLogFilterQuery query, {bool stateful = false}) => renderLog(
    t,
    stateful
        ? StatefulBuilder(
            builder: (context, setState) => WorkflowLogFilter(
              queryParams: query,
              setQueryParams: (next) {
                calls.add(next);
                setState(() => query = next);
              },
            ),
          )
        : WorkflowLogFilter(queryParams: query, setQueryParams: calls.add),
  );

  Finder searchField() =>
      find.descendant(of: find.byKey(const ValueKey('workflow-log-keyword')), matching: find.byType(EditableText));

  Future<void> open(WidgetTester t, String trigger) async {
    await t.tap(find.text(trigger).first);
    await settle(t);
  }

  Future<void> choose(WidgetTester t, String option) async {
    await t.tap(find.text(option).last);
    await settle(t);
  }

  group('Filter', () {
    group('Rendering', () {
      testWidgets('should render all filter components', (t) async {
        await renderFilter(t, q());
        expect(find.text('All'), findsOneWidget);
        expect(find.text('app-log.filter.period.last7days'), findsOneWidget);
        expect(searchField(), findsOneWidget);
      });
    });

    group('Status Filter', () {
      testWidgets('should display current status value', (t) async {
        await renderFilter(t, q(status: 'succeeded'));
        expect(find.text('Success'), findsOneWidget);
      });

      testWidgets('should open status dropdown when clicked', (t) async {
        await renderFilter(t, q());
        await open(t, 'All');
        for (final name in ['Success', 'Fail', 'Stop', 'Partial Success']) {
          expect(find.text(name), findsOneWidget);
        }
      });

      testWidgets('should call setQueryParams when status is selected', (t) async {
        await renderFilter(t, q());
        await open(t, 'All');
        await choose(t, 'Success');
        expect(calls.last, q(status: 'succeeded'));
      });

      testWidgets('should reset to all when status is cleared', (t) async {
        await renderFilter(t, q(status: 'succeeded'));
        await tapButton(t, 'common.operation.clear Success');
        expect(calls.last, q());
      });

      testWidgets('should display correct label for %s status', (t) async {
        for (final (value, label) in [
          ('all', 'All'),
          ('succeeded', 'Success'),
          ('failed', 'Fail'),
          ('stopped', 'Stop'),
          ('partial-succeeded', 'Partial Success'),
        ]) {
          await renderFilter(t, q(status: value));
          expect(find.text(label), findsOneWidget, reason: value);
        }
      });
    });

    group('Time Period Filter', () {
      testWidgets('should keep all periods for sandbox workspaces outside Cloud', (t) async {
        await renderFilter(t, q());
        await open(t, 'app-log.filter.period.last7days');
        expect(find.byKey(const ValueKey('chip-option-1')), findsOneWidget);
        for (var k = 1; k <= 9; k++) {
          expect(find.byKey(ValueKey('chip-option-$k')), findsOneWidget);
        }
      });

      testWidgets('should display current period value', (t) async {
        await renderFilter(t, q(period: '1'));
        expect(find.text('app-log.filter.period.today'), findsOneWidget);
      });

      testWidgets('should open period dropdown when clicked', (t) async {
        await renderFilter(t, q());
        await open(t, 'app-log.filter.period.last7days');
        for (final name in ['today', 'last4weeks', 'last3months', 'allTime']) {
          expect(find.text('app-log.filter.period.$name'), findsOneWidget);
        }
      });

      testWidgets('should call setQueryParams when period is selected', (t) async {
        await renderFilter(t, q());
        await open(t, 'app-log.filter.period.last7days');
        await choose(t, 'app-log.filter.period.allTime');
        expect(calls.last, q(period: '9'));
      });

      testWidgets('should reset period to allTime when cleared', (t) async {
        await renderFilter(t, q(period: '2'));
        await tapButton(t, 'common.operation.clear app-log.filter.period.last7days');
        expect(calls.last, q(period: '9'));
      });
    });

    group('Keyword Search', () {
      testWidgets('should display current keyword value', (t) async {
        await renderFilter(t, q(keyword: 'test search'));
        expect(t.widget<EditableText>(searchField()).controller.text, 'test search');
      });

      testWidgets('should call setQueryParams when typing in search', (t) async {
        await renderFilter(t, q(), stateful: true);
        await t.enterText(searchField(), 'workflow');
        await settle(t);
        expect(calls.last.keyword, 'workflow');
      });

      testWidgets('should clear keyword when clear button is clicked', (t) async {
        await renderFilter(t, q(keyword: 'test'));
        await tapButton(t, 'common.operation.clear');
        expect(calls.last, q(keyword: ''));
      });

      testWidgets('should update on direct input change', (t) async {
        await renderFilter(t, q());
        await t.enterText(searchField(), 'new search');
        await settle(t);
        expect(calls.last, q(keyword: 'new search'));
      });
    });

    group('TIME_PERIOD_MAPPING', () {
      test('should have correct mapping for today', () => expect(timePeriodMapping()['1'], (value: 0, name: 'today')));
      test(
        'should have correct mapping for last 7 days',
        () => expect(timePeriodMapping()['2'], (value: 7, name: 'last7days')),
      );
      test(
        'should have correct mapping for last 4 weeks',
        () => expect(timePeriodMapping()['3'], (value: 28, name: 'last4weeks')),
      );
      test(
        'should have correct mapping for all time',
        () => expect(timePeriodMapping()['9'], (value: -1, name: 'allTime')),
      );
      test('should have all 9 predefined time periods', () => expect(timePeriodMapping().keys, hasLength(9)));
      test('TIME_PERIOD_MAPPING[%s] should have name=%s and correct value', () {
        for (final (key, name, value) in [
          ('1', 'today', 0),
          ('2', 'last7days', 7),
          ('3', 'last4weeks', 28),
          ('9', 'allTime', -1),
        ]) {
          expect(timePeriodMapping()[key]!.name, name);
          expect(timePeriodMapping()[key]!.value, value);
        }
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle undefined keyword gracefully', (t) async {
        await renderFilter(t, q());
        expect(t.widget<EditableText>(searchField()).controller.text, '');
      });

      testWidgets('should handle empty string keyword', (t) async {
        await renderFilter(t, q(keyword: ''));
        expect(t.widget<EditableText>(searchField()).controller.text, '');
      });

      testWidgets('should preserve other query params when updating status', (t) async {
        await renderFilter(t, q(keyword: 'test', period: '3'));
        await open(t, 'All');
        await choose(t, 'Success');
        expect(calls.last, q(status: 'succeeded', period: '3', keyword: 'test'));
      });

      testWidgets('should preserve other query params when updating period', (t) async {
        await renderFilter(t, q(keyword: 'test', status: 'failed'));
        await open(t, 'app-log.filter.period.last7days');
        await choose(t, 'app-log.filter.period.today');
        expect(calls.last, q(status: 'failed', period: '1', keyword: 'test'));
      });

      testWidgets('should preserve other query params when updating keyword', (t) async {
        await renderFilter(t, q(status: 'failed', period: '3'));
        await t.enterText(searchField(), 'a');
        await settle(t);
        expect(calls.last, q(status: 'failed', period: '3', keyword: 'a'));
      });
    });

    group('Integration', () {
      testWidgets('should render with all filters visible simultaneously', (t) async {
        await renderFilter(t, q(status: 'succeeded', period: '1', keyword: 'integration test'));
        expect(find.text('Success'), findsOneWidget);
        expect(find.text('app-log.filter.period.today'), findsOneWidget);
        expect(t.widget<EditableText>(searchField()).controller.text, 'integration test');
      });

      testWidgets('should have proper layout with flex and gap', (t) async {
        await renderFilter(t, q());
        // `flex flex-row flex-wrap gap-2 mb-2`.
        final wrap = t.widget<Wrap>(find.descendant(of: find.byType(WorkflowLogFilter), matching: find.byType(Wrap)));
        expect(wrap.direction, Axis.horizontal);
        expect(wrap.spacing, 8);
        expect(wrap.runSpacing, 8);
        expect(find.byType(LogChip), findsNWidgets(2));
      });
    });
  });
}
