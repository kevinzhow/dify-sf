// dify-spec: web/app/components/app/workflow-log/__tests__/list.spec.tsx
import 'package:collab_client/collab_client.dart' show AppInfo;
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/app_detail/logs/logs_data.dart';
import 'package:dify_sf_app/src/app_detail/logs/workflow_log.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late int refreshes;
  late List<String> replayed;
  setUp(() {
    refreshes = 0;
    replayed = [];
  });

  Widget runView(BuildContext context, String detailUrl, String tracingUrl) => Column(
    key: const ValueKey('workflow-run'),
    children: [
      Text(detailUrl, key: const ValueKey('run-detail-url')),
      Text(tracingUrl, key: const ValueKey('tracing-list-url')),
    ],
  );

  Future<void> renderList(WidgetTester t, Json? logs, {AppInfo? app, bool noApp = false, VoidCallback? onRefresh}) {
    final a = noApp ? null : (app ?? mockApp());
    return renderLog(
      t,
      SingleChildScrollView(
        child: WorkflowAppLogList(
          logs: logs,
          app: a,
          onRefresh: onRefresh ?? () => refreshes++,
          onReplay: (runId) => replayed.add('/app/${a?.id}/workflow?replayRunId=$runId'),
          runBuilder: runView,
        ),
      ),
    );
  }

  Finder rows() => find.byWidgetPredicate((w) => w is DifyTableRow);
  bool drawerOpen() => find.byKey(const ValueKey('log-drawer')).evaluate().isNotEmpty;

  group('WorkflowAppLogList', () {
    group('Rendering', () {
      testWidgets('should render loading state when logs are undefined', (t) async {
        await renderList(t, null);
        expect(find.byKey(const ValueKey('logs-loading')), findsOneWidget);
      });

      testWidgets('should render loading state when appDetail is undefined', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]), noApp: true);
        expect(find.byKey(const ValueKey('logs-loading')), findsOneWidget);
      });

      testWidgets('should render table when data is available', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]));
        expect(find.byType(DifyTable), findsOneWidget);
      });

      testWidgets('should render all table headers', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]));
        for (final h in ['startTime', 'status', 'runtime', 'tokens', 'user']) {
          expect(find.text('APP-LOG.TABLE.HEADER.${h.toUpperCase()}'), findsOneWidget, reason: h);
        }
      });

      testWidgets('should render trigger column for workflow apps', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]), app: mockApp(mode: 'workflow'));
        expect(find.text('APP-LOG.TABLE.HEADER.TRIGGERED_FROM'), findsOneWidget);
      });

      testWidgets('should not render trigger column for non-workflow apps', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]), app: mockApp(mode: 'advanced-chat'));
        expect(find.text('APP-LOG.TABLE.HEADER.TRIGGERED_FROM'), findsNothing);
      });
    });

    group('Status Display', () {
      Future<void> expectStatus(WidgetTester t, String status, String label) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog(workflowRun: mockWorkflowRun(status: status))]));
        expect(find.text(label), findsOneWidget);
      }

      testWidgets('should render success status correctly', (t) => expectStatus(t, 'succeeded', 'SUCCESS'));
      testWidgets('should render failure status correctly', (t) => expectStatus(t, 'failed', 'FAILURE'));
      testWidgets('should render stopped status correctly', (t) => expectStatus(t, 'stopped', 'STOP'));
      testWidgets('should render running status correctly', (t) => expectStatus(t, 'running', 'RUNNING'));
      testWidgets(
        'should render partial-succeeded status correctly',
        (t) => expectStatus(t, 'partial-succeeded', 'PARTIAL SUCCESS'),
      );
    });

    group('User Info Display', () {
      testWidgets('should display account name when created by account', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(createdByAccount: {'id': 'acc-1', 'name': 'John Doe', 'email': 'john@example.com'}),
          ]),
        );
        expect(find.text('John Doe'), findsOneWidget);
      });

      testWidgets('should display end user session id when created by end user', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(
              createdByAccount: null,
              createdByEndUser: {
                'id': 'user-1',
                'type': 'browser',
                'is_anonymous': false,
                'session_id': 'session-abc-123',
              },
            ),
          ]),
        );
        expect(find.text('session-abc-123'), findsOneWidget);
      });

      testWidgets('should display N/A when no user info', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog(createdByAccount: null)]));
        expect(find.text('N/A'), findsOneWidget);
      });
    });

    group('Sorting', () {
      testWidgets('should sort logs in descending order by default', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(id: 'log-1', createdAt: 1000),
            mockWorkflowLog(id: 'log-2', createdAt: 2000),
            mockWorkflowLog(id: 'log-3', createdAt: 3000),
          ]),
        );
        expect(rows(), findsNWidgets(3));
        final keys = [for (final e in rows().evaluate()) (e.widget.key! as ValueKey<String>).value];
        expect(keys, ['workflow-log-row-log-3', 'workflow-log-row-log-2', 'workflow-log-row-log-1']);
      });

      testWidgets('should toggle sort order when clicking on start time header', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(id: 'log-1', createdAt: 1000),
            mockWorkflowLog(id: 'log-2', createdAt: 2000),
          ]),
        );
        await t.tap(find.byKey(const ValueKey('workflow-log-sort')));
        await settle(t);
        expect(find.byKey(const ValueKey('workflow-log-sort-asc')), findsOneWidget);
        final keys = [for (final e in rows().evaluate()) (e.widget.key! as ValueKey<String>).value];
        expect(keys, ['workflow-log-row-log-1', 'workflow-log-row-log-2']);
      });

      testWidgets('should render sort arrow icon', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]));
        expect(find.byKey(const ValueKey('workflow-log-sort-desc')), findsOneWidget);
      });
    });

    group('Drawer', () {
      testWidgets('should open drawer when clicking on a log row', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(
              id: 'log-1',
              workflowRun: mockWorkflowRun(id: 'run-456'),
            ),
          ]),
          app: mockApp(id: 'app-123'),
        );
        await t.tap(rows().first);
        await settle(t);
        expect(drawerOpen(), isTrue);
        expect(find.text('app-log.runDetail.workflowTitle'), findsOneWidget);
        expect(find.text('/apps/app-123/workflow-runs/run-456'), findsOneWidget);
      });

      testWidgets('restores focus to the selected log after %s opening and refresh', (t) async {
        for (final opening in ['keyboard', 'row']) {
          refreshes = 0;
          await renderList(
            t,
            mockLogsResponse([
              mockWorkflowLog(id: 'log-1', createdAt: 100),
              mockWorkflowLog(id: 'log-2', createdAt: 200),
            ]),
          );
          final triggerFinder = find.byWidgetPredicate((w) => w is LogDrawerTrigger && w.text.isNotEmpty).last;
          final trigger = t.widget<LogDrawerTrigger>(triggerFinder);
          if (opening == 'keyboard') {
            trigger.focusNode!.requestFocus();
            await t.pump();
            await t.sendKeyEvent(LogicalKeyboardKey.enter);
          } else {
            await t.tap(rows().at(1));
          }
          await settle(t);
          expect(drawerOpen(), isTrue, reason: opening);
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await settle(t);
          expect(drawerOpen(), isFalse, reason: opening);
          expect(trigger.focusNode!.hasFocus, isTrue, reason: opening);
          expect(refreshes, 1, reason: opening);
        }
      });

      testWidgets('should close drawer and call onRefresh when closing', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]));
        await t.tap(rows().first);
        await settle(t);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t);
        expect(refreshes, 1);
        expect(drawerOpen(), isFalse);
      });

      testWidgets('should highlight selected row', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]));
        expect(t.widget<DifyTableRow>(rows().first).selected, isFalse);
        await t.tap(rows().first);
        await settle(t);
        expect(t.widget<DifyTableRow>(rows().first).selected, isTrue);
      });
    });

    group('Replay Functionality', () {
      testWidgets('should allow replay when triggered from app-run', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(
              workflowRun: mockWorkflowRun(id: 'run-to-replay', triggeredFrom: 'app-run'),
            ),
          ]),
          app: mockApp(id: 'app-replay'),
        );
        await t.tap(rows().first);
        await settle(t);
        await tapButton(t, 'app-log.runDetail.testWithParams');
        expect(replayed, ['/app/app-replay/workflow?replayRunId=run-to-replay']);
      });

      testWidgets('should allow replay when triggered from debugging', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(
              workflowRun: mockWorkflowRun(id: 'debug-run', triggeredFrom: 'debugging'),
            ),
          ]),
          app: mockApp(id: 'app-debug'),
        );
        await t.tap(rows().first);
        await settle(t);
        expect(button('app-log.runDetail.testWithParams'), findsOneWidget);
      });

      testWidgets('should not show replay for webhook triggers', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(
              workflowRun: mockWorkflowRun(id: 'webhook-run', triggeredFrom: 'webhook'),
            ),
          ]),
          app: mockApp(id: 'app-webhook'),
        );
        await t.tap(rows().first);
        await settle(t);
        expect(button('app-log.runDetail.testWithParams'), findsNothing);
      });
    });

    group('Unread Indicator', () {
      testWidgets('should show unread indicator for unread logs', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog()]));
        expect(find.byKey(const ValueKey('log-unread-dot')), findsOneWidget);
      });

      testWidgets('should not show unread indicator for read logs', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog(readAt: 1710000001)]));
        expect(find.byKey(const ValueKey('log-unread-dot')), findsNothing);
      });
    });

    group('Runtime Display', () {
      testWidgets('should display elapsed time with 3 decimal places', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog(workflowRun: mockWorkflowRun(elapsedTime: 1.23456))]));
        expect(find.text('1.235s'), findsOneWidget);
      });

      testWidgets('should display 0 elapsed time with special styling', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog(workflowRun: mockWorkflowRun(elapsedTime: 0))]));
        expect(t.widget<Text>(find.text('0.000s')).style?.color, DifyColors.textQuaternary);
      });
    });

    group('Token Display', () {
      testWidgets('should display total tokens', (t) async {
        await renderList(t, mockLogsResponse([mockWorkflowLog(workflowRun: mockWorkflowRun(totalTokens: 12345))]));
        expect(find.text('12345'), findsOneWidget);
      });
    });

    group('Empty State', () {
      testWidgets('should render empty table when logs data is empty', (t) async {
        await renderList(t, mockLogsResponse([]));
        expect(find.byType(DifyTable), findsOneWidget);
        expect(find.byKey(const ValueKey('log-table-header')), findsOneWidget);
        expect(rows(), findsNothing);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle multiple logs correctly', (t) async {
        await renderList(
          t,
          mockLogsResponse([
            mockWorkflowLog(id: 'log-1', createdAt: 1000),
            mockWorkflowLog(id: 'log-2', createdAt: 2000),
            mockWorkflowLog(id: 'log-3', createdAt: 3000),
          ]),
        );
        expect(rows(), findsNWidgets(3));
      });

      testWidgets('should handle logs with missing workflow_run data gracefully', (t) async {
        await renderList(
          t,
          mockLogsResponse([mockWorkflowLog(workflowRun: mockWorkflowRun(elapsedTime: 0, totalTokens: 0))]),
        );
        expect(find.text('0.000s'), findsOneWidget);
        expect(find.text('0'), findsOneWidget);
      });

      testWidgets('should handle null workflow_run.triggered_from for non-workflow apps', (t) async {
        await renderList(
          t,
          mockLogsResponse([mockWorkflowLog(workflowRun: mockWorkflowRun(triggeredFrom: null))]),
          app: mockApp(mode: 'advanced-chat'),
        );
        expect(find.text('APP-LOG.TABLE.HEADER.TRIGGERED_FROM'), findsNothing);
      });
    });
  });
}
