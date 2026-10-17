// dify-spec: web/app/components/workflow/header/__tests__/view-history.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_input.dart';
import 'package:dify_sf_app/src/workflow_editor/header/format.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/header/view_history.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

DifyJson createHistoryItem([DifyJson overrides = const {}]) => {
  'id': 'run-1',
  'version': 'v1',
  'graph': {'nodes': [], 'edges': []},
  'inputs': {},
  'status': 'succeeded',
  'outputs': {},
  'elapsed_time': 1,
  'total_tokens': 2,
  'total_steps': 3,
  'created_at': 100,
  'finished_at': 120,
  'created_by_account': {'id': 'user-1', 'name': 'Alice', 'email': 'alice@example.com'},
  ...overrides,
};

void main() {
  group('ViewHistory', () {
    late int fetches, cleared, backups, cancels, inputPanelsClosed;
    WorkflowHeaderData data({Future<List<DifyJson>> Function()? fetch, bool chat = false}) {
      fetches = cleared = backups = cancels = inputPanelsClosed = 0;
      return WorkflowHeaderData(
        isChatMode: chat,
        fetchRunHistory: () {
          fetches++;
          return fetch?.call() ?? Future.value(const []);
        },
        onClearLogAndMessageModal: () => cleared++,
        handleBackupDraft: () => backups++,
        handleNodesCancelSelected: () => cancels++,
        closeAllInputFieldPanels: () => inputPanelsClosed++,
        formatters: HeaderFormatters(
          formatTimeFromNow: (ms) => 'from-now:$ms',
          formatWorkflowRunIdentifier: (finishedAt, [status = 'Running']) => ' ($status)',
        ),
      );
    }

    testWidgets('defers fetching until the history popup is opened and renders the empty state', (t) async {
      await renderWorkflowComponent(t, const ViewHistory(withText: true), data: data());
      expect(fetches, 0);
      expect(find.text('workflow.common.runHistory'), findsNothing);

      await t.tap(find.text('workflow.common.showRunHistory'));
      await settle(t);
      expect(fetches, 1);
      expect(find.text('workflow.common.notRunning'), findsOneWidget);
      expect(find.text('workflow.common.showRunHistory'), findsOneWidget);
    });

    testWidgets('renders the icon trigger variant and loading state, and clears log modals on trigger click', (
      t,
    ) async {
      await renderWorkflowComponent(t, const ViewHistory(), data: data(fetch: pending));
      await t.tap(find.bySemanticsLabel('workflow.common.viewRunHistory'));
      await settle(t);
      expect(cleared, 1);
      expect(find.byType(HeaderLoading), findsOneWidget);
    });

    testWidgets('renders workflow run history items and updates the workflow store when one is selected', (t) async {
      final paused = createHistoryItem({'id': 'run-paused', 'status': 'paused', 'created_at': 101, 'finished_at': 0});
      final failed = createHistoryItem({'id': 'run-failed', 'status': 'failed', 'created_at': 102, 'finished_at': 130});
      final succeeded = createHistoryItem({
        'id': 'run-succeeded',
        'status': 'succeeded',
        'created_at': 103,
        'finished_at': 140,
      });
      final s = await renderWorkflowComponent(
        t,
        const ViewHistory(withText: true),
        data: data(fetch: () async => [paused, failed, succeeded]),
        initialStoreState: (s) => s
          ..setHistoryWorkflowData(failed)
          ..showInputsPanel.value = true
          ..showEnvPanel.value = true
          ..setControlMode(ControlMode.pointer),
      );
      await t.tap(find.text('workflow.common.showRunHistory'));
      await settle(t);
      expect(find.text('Test Run (paused)'), findsOneWidget);
      expect(find.text('Test Run (failed)'), findsOneWidget);
      expect(find.text('Test Run (succeeded)'), findsOneWidget);

      await t.tap(find.text('Test Run (succeeded)'));
      await settle(t);
      expect(s.historyWorkflowData.value, succeeded);
      expect(s.showInputsPanel.value, isFalse);
      expect(s.showEnvPanel.value, isFalse);
      expect(s.controlMode.value, ControlMode.hand);
      expect(inputPanelsClosed, 1);
      expect(backups, 1);
      expect(cancels, 1);
      expect(s.showDebugAndPreviewPanel.value, isFalse);
    });

    testWidgets('renders chat history labels without workflow status icons in chat mode', (t) async {
      final chatRun = createHistoryItem({'id': 'chat-run', 'status': 'failed'});
      await renderWorkflowComponent(
        t,
        const ViewHistory(withText: true),
        data: data(chat: true, fetch: () async => [chatRun]),
      );
      await t.tap(find.text('workflow.common.showRunHistory'));
      await settle(t);
      expect(find.text('Test Chat (failed)'), findsOneWidget);
    });

    testWidgets('closes the popup from the close button and clears log modals', (t) async {
      await renderWorkflowComponent(t, const ViewHistory(withText: true), data: data());
      await t.tap(find.text('workflow.common.showRunHistory'));
      await settle(t);
      await t.tap(find.bySemanticsLabel('common.operation.close'));
      await settle(t);
      expect(cleared, 1);
      expect(find.text('workflow.common.runHistory'), findsNothing);
    });
  });
}
