// dify-spec: web/app/components/app/workflow-log/__tests__/detail.spec.tsx
import 'package:dify_sf_app/src/app_detail/logs/workflow_log.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store_scope.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late List<String> pushed;
  late int closes;
  setUp(() {
    pushed = [];
    closes = 0;
  });

  Widget runView(BuildContext context, String detailUrl, String tracingUrl) => Column(
    key: const ValueKey('workflow-run'),
    children: [
      Text(detailUrl, key: const ValueKey('run-detail-url')),
      Text(tracingUrl, key: const ValueKey('tracing-list-url')),
    ],
  );

  /// The panel with the open app [appId] (Dify's app store; null: none).
  Future<void> renderPanel(WidgetTester t, String runID, {String? appId = 'test-app-id', bool canReplay = false}) =>
      renderLog(
        t,
        SizedBox(
          width: 600,
          height: 800,
          child: WorkflowLogDetailPanel(
            runID: runID,
            appId: appId,
            canReplay: canReplay,
            onClose: () => closes++,
            onReplay: (run) => pushed.add('/app/$appId/workflow?replayRunId=$run'),
            runBuilder: runView,
          ),
        ),
      );

  String text(WidgetTester t, String key) => t.widget<Text>(find.byKey(ValueKey(key))).data!;

  group('DetailPanel', () {
    group('Rendering', () {
      testWidgets('should render workflow title', (t) async {
        await renderPanel(t, 'run-123');
        expect(find.text('app-log.runDetail.workflowTitle'), findsOneWidget);
      });

      testWidgets('should render close button', (t) async {
        await renderPanel(t, 'run-123');
        expect(button('common.operation.close'), findsOneWidget);
      });

      testWidgets('should render Run component with correct URLs', (t) async {
        await renderPanel(t, 'run-789', appId: 'app-456');
        expect(find.byKey(const ValueKey('workflow-run')), findsOneWidget);
        expect(text(t, 'run-detail-url'), '/apps/app-456/workflow-runs/run-789');
        expect(text(t, 'tracing-list-url'), '/apps/app-456/workflow-runs/run-789/node-executions');
      });

      testWidgets('should render WorkflowContextProvider wrapper', (t) async {
        await renderPanel(t, 'run-123');
        expect(find.byType(WorkflowStoreProvider), findsOneWidget);
      });
    });

    group('Props', () {
      testWidgets('should not render replay button when canReplay is false (default)', (t) async {
        await renderPanel(t, 'run-123');
        expect(button('app-log.runDetail.testWithParams'), findsNothing);
      });

      testWidgets('should render replay button when canReplay is true', (t) async {
        await renderPanel(t, 'run-123', canReplay: true);
        expect(button('app-log.runDetail.testWithParams'), findsOneWidget);
      });

      testWidgets('should use empty URL when runID is empty', (t) async {
        await renderPanel(t, '');
        expect(text(t, 'run-detail-url'), '');
        expect(text(t, 'tracing-list-url'), '');
      });
    });

    group('User Interactions', () {
      testWidgets('should call onClose when close button is clicked', (t) async {
        await renderPanel(t, 'run-123');
        await tapButton(t, 'common.operation.close');
        expect(closes, 1);
      });

      testWidgets('should navigate to workflow page with replayRunId when replay button is clicked', (t) async {
        await renderPanel(t, 'run-to-replay', appId: 'app-replay-test', canReplay: true);
        await tapButton(t, 'app-log.runDetail.testWithParams');
        expect(pushed, ['/app/app-replay-test/workflow?replayRunId=run-to-replay']);
      });

      testWidgets('should not navigate when replay clicked but appDetail is missing', (t) async {
        await renderPanel(t, 'run-123', appId: null, canReplay: true);
        await tapButton(t, 'app-log.runDetail.testWithParams');
        expect(pushed, isEmpty);
      });
    });

    group('URL Generation', () {
      testWidgets('should generate correct run detail URL', (t) async {
        await renderPanel(t, 'my-run', appId: 'my-app');
        expect(text(t, 'run-detail-url'), '/apps/my-app/workflow-runs/my-run');
      });

      testWidgets('should generate correct tracing list URL', (t) async {
        await renderPanel(t, 'my-run', appId: 'my-app');
        expect(text(t, 'tracing-list-url'), '/apps/my-app/workflow-runs/my-run/node-executions');
      });

      testWidgets('should handle special characters in runID', (t) async {
        await renderPanel(t, 'run-with-special-123', appId: 'app-id');
        expect(text(t, 'run-detail-url'), '/apps/app-id/workflow-runs/run-with-special-123');
      });
    });

    group('Store Integration', () {
      testWidgets('should read appDetail from store', (t) async {
        await renderPanel(t, 'run-123', appId: 'store-app-id');
        expect(text(t, 'run-detail-url'), '/apps/store-app-id/workflow-runs/run-123');
      });

      testWidgets('should handle undefined appDetail from store gracefully', (t) async {
        await renderPanel(t, 'run-123', appId: null);
        expect(find.byKey(const ValueKey('workflow-run')), findsOneWidget);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle empty runID', (t) async {
        await renderPanel(t, '');
        expect(text(t, 'run-detail-url'), '');
        expect(text(t, 'tracing-list-url'), '');
      });

      testWidgets('should handle very long runID', (t) async {
        final longRunId = 'a' * 100;
        await renderPanel(t, longRunId, appId: 'app-id');
        expect(text(t, 'run-detail-url'), '/apps/app-id/workflow-runs/$longRunId');
      });

      testWidgets('should render replay button with correct aria-label', (t) async {
        await renderPanel(t, 'run-123', canReplay: true);
        expect(button('app-log.runDetail.testWithParams'), findsOneWidget);
      });

      testWidgets('should maintain proper component structure', (t) async {
        await renderPanel(t, 'run-123');
        expect(find.byKey(const ValueKey('workflow-log-detail')), findsOneWidget);
        expect(find.byKey(const ValueKey('workflow-log-detail-header')), findsOneWidget);
      });
    });

    group('Tooltip', () {
      testWidgets('should have tooltip on replay button', (t) async {
        await renderPanel(t, 'run-123', canReplay: true);
        final replay = find.byKey(const ValueKey('workflow-log-replay'));
        expect(replay, findsOneWidget);
        final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: t.getCenter(replay));
        await gesture.moveTo(t.getCenter(replay));
        await t.pump(const Duration(milliseconds: 400));
        await settle(t);
        expect(find.text('app-log.runDetail.testWithParams'), findsOneWidget);
        await gesture.removePointer();
      });
    });
  });
}
