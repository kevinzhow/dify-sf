// dify-spec: web/app/components/app/workflow-log/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/app_detail/logs/workflow_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

void main() {
  late RecordingLogsSource source;
  setUp(() => source = RecordingLogsSource());

  Future<void> renderLogs(WidgetTester t, {String id = 'test-app-id', String mode = 'workflow'}) => renderLog(
    t,
    WorkflowLogs(
      app: mockApp(id: id, mode: mode),
      source: source,
      debounce: Duration.zero,
    ),
  );

  Map<String, Object?>? lastParams() => source.workflowLogsCalls.lastOrNull?.params;

  Future<void> pick(WidgetTester t, String trigger, String option) async {
    await t.tap(find.text(trigger).first);
    await settle(t);
    await t.tap(find.text(option).last);
    await settle(t);
  }

  group('Logs Container', () {
    group('Rendering', () {
      testWidgets('should render title and subtitle', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        expect(find.text('app-log.workflowTitle'), findsOneWidget);
        expect(find.text('app-log.workflowSubtitle'), findsOneWidget);
      });

      testWidgets('should render Filter component', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        // The search input (Cloud's retention upgrade notice is not part of dify-sf).
        expect(find.byKey(const ValueKey('workflow-log-keyword')), findsOneWidget);
        expect(find.text('common.operation.search'), findsOneWidget);
      });
    });

    group('Loading State', () {
      testWidgets('should show loading spinner when data is undefined', (t) async {
        await renderLogs(t);
        expect(find.byKey(const ValueKey('logs-loading')), findsOneWidget);
      });

      testWidgets('should not show loading spinner when data is available', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([mockWorkflowLog()], 1);
        await renderLogs(t);
        expect(find.byKey(const ValueKey('logs-loading')), findsNothing);
      });
    });

    group('Empty State', () {
      testWidgets('should render empty element when total is 0', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        expect(find.text('app-log.table.empty.element.title'), findsOneWidget);
        expect(find.byType(LogTable), findsNothing);
      });
    });

    group('Data Fetching', () {
      testWidgets('should call useWorkflowLogs with correct appId and default params', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        final call = source.workflowLogsCalls.last;
        expect(call.appId, 'test-app-id');
        expect(call.params, containsPair('page', 1));
        expect(call.params, containsPair('detail', true));
        expect(call.params, containsPair('limit', appPageLimit));
      });

      testWidgets('should include date filters for non-allTime periods', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        expect(lastParams(), contains('created_at__after'));
        expect(lastParams(), contains('created_at__before'));
      });

      testWidgets('should not include status param when status is all', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        expect(lastParams(), isNot(contains('status')));
      });
    });

    group('Filter Integration', () {
      testWidgets('should update query when selecting status filter', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        await pick(t, 'All', 'Success');
        expect(lastParams(), containsPair('status', 'succeeded'));
      });

      testWidgets('should update query when selecting period filter', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        await pick(t, 'app-log.filter.period.last7days', 'app-log.filter.period.allTime');
        expect(lastParams(), isNot(contains('created_at__after')));
        expect(lastParams(), isNot(contains('created_at__before')));
      });

      testWidgets('should update query when typing keyword', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t);
        await t.enterText(
          find.descendant(of: find.byKey(const ValueKey('workflow-log-keyword')), matching: find.byType(EditableText)),
          'test-keyword',
        );
        await settle(t);
        expect(lastParams(), containsPair('keyword', 'test-keyword'));
      });
    });

    group('Pagination', () {
      testWidgets('should not render pagination when total is less than limit', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([mockWorkflowLog()], 1);
        await renderLogs(t);
        expect(find.byType(LogPagination), findsNothing);
      });

      testWidgets('should render pagination when total exceeds limit', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([
          for (var i = 0; i < appPageLimit; i++) mockWorkflowLog(id: 'log-$i'),
        ], appPageLimit + 10);
        await renderLogs(t);
        expect(find.byType(LogTable), findsOneWidget);
        expect(find.byType(LogPagination), findsOneWidget);
      });
    });

    group('List Rendering', () {
      testWidgets('should render List component when data is available', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([mockWorkflowLog()], 1);
        await renderLogs(t);
        expect(find.byType(LogTable), findsOneWidget);
      });

      testWidgets('should display log data in table', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([
          mockWorkflowLog(workflowRun: mockWorkflowRun(status: 'succeeded', totalTokens: 500)),
        ], 1);
        await renderLogs(t);
        expect(find.text('SUCCESS'), findsOneWidget);
        expect(find.text('500'), findsOneWidget);
      });
    });

    group('TIME_PERIOD_MAPPING', () {
      test('should export TIME_PERIOD_MAPPING with correct values', () {
        final m = timePeriodMapping();
        expect(m['1'], (value: 0, name: 'today'));
        expect(m['2'], (value: 7, name: 'last7days'));
        expect(m['9'], (value: -1, name: 'allTime'));
        expect(m.keys, hasLength(9));
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle different app modes', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([mockWorkflowLog()], 1);
        await renderLogs(t, mode: 'advanced-chat');
        expect(find.text('APP-LOG.TABLE.HEADER.TRIGGERED_FROM'), findsNothing);
        expect(find.text('app-log.table.header.triggered_from'), findsNothing);
      });

      testWidgets('should handle error state from useWorkflowLogs', (t) async {
        source.workflowLogsError = Exception('Failed to fetch');
        await renderLogs(t);
        expect(find.byKey(const ValueKey('logs-loading')), findsOneWidget);
      });

      testWidgets('should handle app with different ID', (t) async {
        source.workflowLogsAnswer = mockLogsResponse([], 0);
        await renderLogs(t, id: 'custom-app-123');
        expect(source.workflowLogsCalls.last.appId, 'custom-app-123');
      });
    });
  });
}
