// dify-spec: web/app/components/workflow/header/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/header-layouts.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/header-in-restoring.spec.tsx
// dify-spec: web/app/components/workflow-app/components/workflow-header/__tests__/chat-variable-trigger.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/header/header_buttons.dart';
import 'package:dify_sf_app/src/workflow_editor/header/run_and_history.dart';
import 'package:dify_sf_app/src/workflow_editor/header/titles.dart';
import 'package:dify_sf_app/src/workflow_editor/header/view_history.dart';
import 'package:dify_sf_app/src/workflow_editor/header/workflow_header.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

DifyJson createCurrentVersion([DifyJson overrides = const {}]) => {
  'id': 'version-1',
  'graph': {
    'nodes': [],
    'edges': [],
    'viewport': {'x': 0, 'y': 0, 'zoom': 1},
  },
  'created_at': 0,
  'created_by': {'id': 'user-1', 'name': 'Tester', 'email': 'tester@example.com'},
  'hash': 'hash-1',
  'updated_at': 0,
  'tool_published': false,
  'environment_variables': [],
  'version': 'latest',
  'version_number': 5,
  'marked_name': '',
  'marked_comment': '',
  ...overrides,
};

const BackupDraft _backup = (
  nodes: [],
  edges: [],
  viewport: (x: 0.0, y: 0.0, zoom: 1.0),
  features: null,
  environmentVariables: [],
);

void main() {
  group('Header', () {
    testWidgets('should render the normal layout', (t) async {
      await renderWorkflowComponent(t, const WorkflowHeader());
      expect(find.byType(HeaderInNormal), findsOneWidget);
      expect(find.byType(HeaderInHistory), findsNothing);
      expect(find.byType(HeaderInRestoring), findsNothing);
    });

    testWidgets('should switch between history and restoring layouts', (t) async {
      await renderWorkflowComponent(
        t,
        const WorkflowHeader(),
        size: const Size(4000, 1200),
        initialStoreState: (s) => s
          ..setHistoryWorkflowData({'id': 'history-1'})
          ..setIsRestoring(true),
      );
      expect(find.byType(HeaderInHistory), findsOneWidget);
      expect(find.byType(HeaderInRestoring), findsOneWidget);
      expect(find.byType(HeaderInNormal), findsNothing);
    });
  });

  group('Header layout components', () {
    group('HeaderInNormal', () {
      testWidgets('should render slots, pass read-only state to action buttons, and start restoring mode', (t) async {
        var backups = 0, inputPanels = 0;
        final deselected = <(String, bool)>[];
        final s = await renderWorkflowComponent(
          t,
          const HeaderInNormal(),
          canvas: canvasWith(['node-selected'], selected: 'node-selected'),
          data: WorkflowHeaderData(
            canEdit: false,
            isChatMode: true,
            left: const Text('left-slot'),
            middle: const Text('middle-slot'),
            handleBackupDraft: () => backups++,
            closeAllInputFieldPanels: () => inputPanels++,
            handleNodeSelect: (id, {cancelSelection = false}) => deselected.add((id, cancelSelection)),
          ),
          initialStoreState: (s) => s
            ..showEnvPanel.value = true
            ..showDebugAndPreviewPanel.value = true
            ..showVariableInspectPanel.value = true
            ..showChatVariablePanel.value = true
            ..showGlobalVariablePanel.value = true,
        );
        expect(find.byType(EditingTitle), findsOneWidget);
        expect(find.byType(ScrollToSelectedNodeButton), findsOneWidget);
        expect(find.text('left-slot'), findsOneWidget);
        expect(find.text('middle-slot'), findsOneWidget);
        expect(find.byType(ChatVariableButton), findsOneWidget);
        expect(t.widget<EnvButton>(find.byType(EnvButton)).disabled, isTrue);
        expect(t.widget<GlobalVariableButton>(find.byType(GlobalVariableButton)).disabled, isTrue);
        expect(find.byType(RunAndHistory), findsOneWidget);

        await t.tap(find.bySemanticsLabel('workflow.common.versionHistory'));

        expect(backups, 1);
        expect(deselected, [('node-selected', true)]);
        expect(inputPanels, 1);
        expect(s.isRestoring.value, isTrue);
        expect(s.showWorkflowVersionHistoryPanel.value, isTrue);
        expect(s.showEnvPanel.value, isFalse);
        expect(s.showDebugAndPreviewPanel.value, isFalse);
        expect(s.showVariableInspectPanel.value, isFalse);
        expect(s.showChatVariablePanel.value, isFalse);
        expect(s.showGlobalVariablePanel.value, isFalse);
      });

      testWidgets('should hide env and global variable buttons when the controls are disabled', (t) async {
        await renderWorkflowComponent(
          t,
          const HeaderInNormal(),
          data: const WorkflowHeaderData(showEnvButton: false, showGlobalVariableButton: false),
        );
        expect(find.byType(EnvButton), findsNothing);
        expect(find.byType(GlobalVariableButton), findsNothing);
      });
    });

    group('HeaderInRestoring', () {
      testWidgets('should cancel restoring mode and reopen the editor state', (t) async {
        var loads = 0;
        final s = await renderWorkflowComponent(
          t,
          const HeaderInRestoring(),
          data: WorkflowHeaderData(handleLoadBackupDraft: () => loads++, restoreWorkflow: (_) async {}),
          initialStoreState: (s) => s
            ..setIsRestoring(true)
            ..setShowWorkflowVersionHistoryPanel(true),
        );
        await t.tap(find.bySemanticsLabel('workflow.common.exitVersions'));
        expect(loads, 1);
        expect(s.isRestoring.value, isFalse);
        expect(s.showWorkflowVersionHistoryPanel.value, isFalse);
      });

      testWidgets('should restore the selected version, clear backup state, and forward lifecycle callbacks', (
        t,
      ) async {
        final restored = <String>[];
        final toasts = <(HeaderToastType, String)>[];
        var refreshes = 0, lastRuns = 0, resets = 0, settled = 0;
        final s = await renderWorkflowComponent(
          t,
          const HeaderInRestoring(),
          data: WorkflowHeaderData(
            restoreWorkflow: (id) async => restored.add(id),
            handleRefreshWorkflowDraft: () => refreshes++,
            invalidAllLastRun: () => lastRuns++,
            resetWorkflowVersionHistory: () => resets++,
            onRestoreSettled: () => settled++,
            toast: (type, m) => toasts.add((type, m)),
          ),
          initialStoreState: (s) => s
            ..setIsRestoring(true)
            ..setShowWorkflowVersionHistoryPanel(true)
            ..setBackupDraft(_backup)
            ..setCurrentVersion(createCurrentVersion())
            ..setNodesWithInspectVars([
              {'nodeId': 'n', 'vars': []},
            ]),
        );
        await t.tap(find.text('workflow.common.restore'));
        await t.pump();
        expect(restored, ['version-1']);
        expect(s.showWorkflowVersionHistoryPanel.value, isFalse);
        expect(s.isRestoring.value, isFalse);
        expect(s.backupDraft.value, isNull);
        expect(refreshes, 1);
        expect(s.nodesWithInspectVars.value, isEmpty);
        expect(lastRuns, 1);
        expect(toasts, [(HeaderToastType.success, 'workflow.versionHistory.action.restoreSuccess')]);
        expect(resets, 1);
        expect(settled, 1);
      });
    });

    group('HeaderInHistory', () {
      testWidgets('should render the history trigger with text and return to edit mode', (t) async {
        var loads = 0;
        final s = await renderWorkflowComponent(
          t,
          WorkflowHeader(data: WorkflowHeaderData(handleLoadBackupDraft: () => loads++)),
          initialStoreState: (s) => s.setHistoryWorkflowData({'id': 'history-1'}),
        );
        expect(find.byType(RunningTitle), findsOneWidget);
        expect(t.widget<ViewHistory>(find.byType(ViewHistory)).withText, isTrue);

        await t.tap(find.text('workflow.common.goBackToEdit'));
        await t.pump();
        expect(loads, 1);
        expect(s.historyWorkflowData.value, isNull);
        expect(find.byType(HeaderInHistory), findsNothing);
      });
    });
  });

  group('HeaderInRestoring', () {
    testWidgets('should disable restore when the flow id is not ready yet', (t) async {
      await renderWorkflowComponent(
        t,
        const HeaderInRestoring(),
        initialStoreState: (s) => s.setCurrentVersion(createCurrentVersion({'version': 'v1'})),
      );
      expect(isEnabled(t, 'workflow.common.restore'), isFalse);
    });

    testWidgets('should enable restore when version and flow id are both ready', (t) async {
      await renderWorkflowComponent(
        t,
        const HeaderInRestoring(),
        data: WorkflowHeaderData(restoreWorkflow: (_) async {}),
        initialStoreState: (s) => s.setCurrentVersion(createCurrentVersion({'version': 'v1'})),
      );
      expect(isEnabled(t, 'workflow.common.restore'), isTrue);
    });

    testWidgets('should keep restore disabled for draft versions even when flow config is ready', (t) async {
      await renderWorkflowComponent(
        t,
        const HeaderInRestoring(),
        data: WorkflowHeaderData(restoreWorkflow: (_) async {}),
        initialStoreState: (s) => s.setCurrentVersion(createCurrentVersion({'version': 'draft'})),
      );
      expect(isEnabled(t, 'workflow.common.restore'), isFalse);
    });
  });

  group('ChatVariableTrigger', () {
    group('Rendering', () {
      testWidgets('should not render when not in chat mode', (t) async {
        await renderWorkflowComponent(t, const HeaderInNormal());
        expect(find.byType(ChatVariableButton), findsNothing);
      });
    });

    group('Props', () {
      testWidgets('should render enabled ChatVariableButton when nodes are editable', (t) async {
        await renderWorkflowComponent(t, const HeaderInNormal(), data: const WorkflowHeaderData(isChatMode: true));
        expect(isEnabled(t, 'workflow.chatVariable.panelTitle'), isTrue);
      });

      testWidgets('should render disabled ChatVariableButton when nodes are read-only', (t) async {
        await renderWorkflowComponent(
          t,
          const HeaderInNormal(),
          data: const WorkflowHeaderData(isChatMode: true),
          initialStoreState: (s) => s.setIsRestoring(true),
        );
        expect(isEnabled(t, 'workflow.chatVariable.panelTitle'), isFalse);
      });
    });
  });
}
