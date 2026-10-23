// dify-spec: web/app/components/workflow/nodes/_base/components/workflow-panel/last-run/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart' show DifySpinner;
import 'package:dify_sf_app/src/workflow_editor/node_panel/last_run.dart' as no_data;
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/node_run_ui.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/result_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../run/run_harness.dart';

const _size = Size(800, 1600);

void main() {
  group('LastRun', () {
    late List<String> updates;
    late int clicks;

    setUp(() {
      updates = [];
      clicks = 0;
    });

    LastRunView view({
      bool isRunAfterSingleRun = false,
      String? runningStatus,
      Map<String, Object?>? lastRun,
      bool isFetching = false,
      bool noLastRun = false,
      bool isPaused = false,
    }) => LastRunView(
      nodeId: 'node-1',
      canSingleRun: true,
      isRunAfterSingleRun: isRunAfterSingleRun,
      onSingleRunClicked: () => clicks++,
      updateNodeRunningStatus: updates.add,
      runningStatus: runningStatus,
      lastRun: lastRun,
      isFetching: isFetching,
      noLastRun: noLastRun,
      isPaused: isPaused,
    );

    ResultPanel panel(WidgetTester t) => t.widget<ResultPanel>(find.byType(ResultPanel));

    testWidgets('should show a loader while fetching the last run before any single run starts', (t) async {
      await renderRun(t, view(isFetching: true), size: _size);
      expect(find.byType(DifySpinner), findsOneWidget);
      expect(find.byType(ResultPanel), findsNothing);
    });

    testWidgets('should show a running result panel while a single run is still executing', (t) async {
      await renderRun(t, view(isRunAfterSingleRun: true, runningStatus: NodeRunningStatus.running), size: _size);
      expect((panel(t).status, panel(t).showSteps), ('running', false));
    });

    testWidgets('should render the no-data state for 404 last-run responses and forward single-run clicks', (t) async {
      await renderRun(t, view(noLastRun: true), size: _size);
      expect(find.byType(no_data.LastRun), findsOneWidget);
      await t.tap(find.text('workflow.debug.noData.runThisNode'));
      expect(clicks, 1);
    });

    testWidgets('should render resolved result data and let paused state override the final status', (t) async {
      await renderRun(
        t,
        view(
          isRunAfterSingleRun: true,
          runningStatus: NodeRunningStatus.succeeded,
          isPaused: true,
          lastRun: {
            'status': NodeRunningStatus.succeeded,
            'execution_metadata': {'total_tokens': 9},
            'created_by_account': {'created_by': 'Alice'},
          },
        ),
        size: _size,
      );
      final p = panel(t);
      expect((p.status, p.totalTokens, p.createdBy, p.showSteps), (NodeRunningStatus.stopped, 9, 'Alice', false));
    });

    testWidgets('should respect stopped and listening one-step statuses', (t) async {
      const last = {'status': NodeRunningStatus.succeeded};
      await renderRun(
        t,
        view(isRunAfterSingleRun: true, runningStatus: NodeRunningStatus.stopped, lastRun: last),
        size: _size,
      );
      expect(panel(t).status, NodeRunningStatus.stopped);
      await renderRun(
        t,
        view(isRunAfterSingleRun: true, runningStatus: NodeRunningStatus.listening, lastRun: last),
        size: _size,
      );
      expect(panel(t).status, NodeRunningStatus.listening);
    });

    testWidgets('should react to page visibility changes while keeping the current result rendered', (t) async {
      await renderRun(
        t,
        view(
          isRunAfterSingleRun: true,
          runningStatus: NodeRunningStatus.succeeded,
          lastRun: const {'status': NodeRunningStatus.succeeded},
        ),
        size: _size,
      );
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(panel(t).status, NodeRunningStatus.succeeded);
    });

    testWidgets('should restore a completed last run when refreshing the canvas loses its transient status', (t) async {
      const last = {'status': NodeRunningStatus.succeeded};
      final status = ValueNotifier<String>(NodeRunningStatus.running);
      await renderRun(
        t,
        ValueListenableBuilder(
          valueListenable: status,
          builder: (context, s, _) => view(isRunAfterSingleRun: true, runningStatus: s, lastRun: last),
        ),
        size: _size,
      );
      status.value = NodeRunningStatus.succeeded;
      await t.pump();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await t.pump();
      status.value = NodeRunningStatus.notStart;
      await t.pump();
      expect(panel(t).status, NodeRunningStatus.succeeded);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(panel(t).status, NodeRunningStatus.succeeded);
      expect(updates, contains(NodeRunningStatus.succeeded));
    });
  });
}
