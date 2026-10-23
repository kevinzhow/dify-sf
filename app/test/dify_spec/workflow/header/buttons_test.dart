// dify-spec: web/app/components/workflow/header/__tests__/editing-title.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/scroll-to-selected-node-button.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/env-button.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/chat-variable-button.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/global-variable-button.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/version-history-button.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/header/format.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_buttons.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/header/hotkey.dart';
import 'package:dify_sf_app/src/workflow_editor/header/titles.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('EditingTitle', () {
    late List<List<Object?>> formatTimeCalls, fromNowCalls;
    WorkflowHeaderData data() {
      formatTimeCalls = [];
      fromNowCalls = [];
      return WorkflowHeaderData(
        formatters: HeaderFormatters(
          formatTime: (s, f) {
            formatTimeCalls.add([s, f]);
            return '08:00:00';
          },
          formatTimeFromNow: (ms) {
            fromNowCalls.add([ms]);
            return '2 hours ago';
          },
        ),
      );
    }

    testWidgets('should render autosave, published time, and syncing status when the draft has metadata', (t) async {
      await renderWorkflowComponent(
        t,
        const EditingTitle(),
        data: data(),
        initialStoreState: (s) => s
          ..draftUpdatedAt.value = 1710000000000
          ..publishedAt.value = 1710003600000
          ..isSyncingWorkflowDraft.value = true,
      );

      expect(formatTimeCalls, contains(equals([1710000000, 'HH:mm:ss'])));
      expect(fromNowCalls, contains(equals([1710003600000])));
      expect(find.bySemanticsLabel('workflow.common.workflowSaveStatus'), findsOneWidget);
      expect(find.text('workflow.common.autoSaved'), findsOneWidget);
      expect(find.text('workflow.common.published'), findsOneWidget);
      expect(find.text('workflow.common.syncingData'), findsOneWidget);
      expect(find.text('08:00:00'), findsOneWidget);
      expect(find.text('2 hours ago'), findsOneWidget);
    });

    testWidgets('should expose autosave time separately from the unpublished status', (t) async {
      await renderWorkflowComponent(
        t,
        const EditingTitle(),
        data: data(),
        initialStoreState: (s) => s
          ..draftUpdatedAt.value = 1710000000000
          ..publishedAt.value = 0
          ..isSyncingWorkflowDraft.value = false,
      );

      expect(formatTimeCalls, contains(equals([1710000000, 'HH:mm:ss'])));
      expect(fromNowCalls, isEmpty);
      expect(find.text('workflow.common.autoSaved'), findsOneWidget);
      expect(find.text('workflow.common.unpublished'), findsOneWidget);
      expect(find.text('workflow.common.syncingData'), findsNothing);
      expect(find.text('08:00:00'), findsOneWidget);
    });
  });

  group('ScrollToSelectedNodeButton', () {
    testWidgets('should render nothing when there is no selected node', (t) async {
      await renderWorkflowComponent(t, const ScrollToSelectedNodeButton(), canvas: canvasWith(['node-1']));
      expect(find.byType(ScrollToSelectedNodeFace), findsNothing);
    });

    testWidgets('should render a button and scroll to the selected node when clicked', (t) async {
      final scrolled = <String>[];
      await renderWorkflowComponent(
        t,
        const ScrollToSelectedNodeButton(),
        canvas: canvasWith(['node-1', 'node-2'], selected: 'node-2'),
        data: WorkflowHeaderData(scrollToNode: scrolled.add),
      );
      await t.tap(find.text('workflow.panel.scrollToSelectedNode'));
      expect(scrolled, ['node-2']);
    });

    testWidgets('should support native keyboard activation', (t) async {
      final scrolled = <String>[];
      await renderWorkflowComponent(
        t,
        const ScrollToSelectedNodeButton(),
        canvas: canvasWith(['node-2'], selected: 'node-2'),
        data: WorkflowHeaderData(scrollToNode: scrolled.add),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      expect(scrolled, ['node-2', 'node-2']);
    });
  });

  group('EnvButton', () {
    testWidgets('should open the environment panel and close the other panels when clicked', (t) async {
      var closed = 0;
      final s = await renderWorkflowComponent(
        t,
        const EnvButton(disabled: false),
        data: WorkflowHeaderData(closeAllInputFieldPanels: () => closed++),
        initialStoreState: (s) => s
          ..showChatVariablePanel.value = true
          ..showGlobalVariablePanel.value = true
          ..showDebugAndPreviewPanel.value = true,
      );
      await t.tap(find.bySemanticsLabel('workflow.env.envPanelTitle'));
      expect(s.showEnvPanel.value, isTrue);
      expect(s.showChatVariablePanel.value, isFalse);
      expect(s.showGlobalVariablePanel.value, isFalse);
      expect(s.showDebugAndPreviewPanel.value, isFalse);
      expect(closed, 1);
    });

    testWidgets('should keep the button disabled when the disabled prop is true', (t) async {
      var closed = 0;
      final s = await renderWorkflowComponent(
        t,
        const EnvButton(disabled: true),
        data: WorkflowHeaderData(closeAllInputFieldPanels: () => closed++),
      );
      await t.tap(find.bySemanticsLabel('workflow.env.envPanelTitle'), warnIfMissed: false);
      expect(isEnabled(t, 'workflow.env.envPanelTitle'), isFalse);
      expect(s.showEnvPanel.value, isFalse);
      expect(closed, 0);
    });
  });

  group('ChatVariableButton', () {
    testWidgets('opens the chat variable panel and closes the other workflow panels', (t) async {
      final s = await renderWorkflowComponent(
        t,
        const ChatVariableButton(disabled: false),
        initialStoreState: (s) => s
          ..showEnvPanel.value = true
          ..showGlobalVariablePanel.value = true
          ..showDebugAndPreviewPanel.value = true,
      );
      await t.tap(find.bySemanticsLabel('workflow.chatVariable.panelTitle'));
      expect(s.showChatVariablePanel.value, isTrue);
      expect(s.showEnvPanel.value, isFalse);
      expect(s.showGlobalVariablePanel.value, isFalse);
      expect(s.showDebugAndPreviewPanel.value, isFalse);
    });

    testWidgets('stays disabled without mutating panel state', (t) async {
      final s = await renderWorkflowComponent(t, const ChatVariableButton(disabled: true));
      await t.tap(find.bySemanticsLabel('workflow.chatVariable.panelTitle'), warnIfMissed: false);
      expect(isEnabled(t, 'workflow.chatVariable.panelTitle'), isFalse);
      expect(s.showChatVariablePanel.value, isFalse);
    });
  });

  group('GlobalVariableButton', () {
    testWidgets('should open the global variable panel and close the other panels when clicked', (t) async {
      var closed = 0;
      final s = await renderWorkflowComponent(
        t,
        const GlobalVariableButton(disabled: false),
        data: WorkflowHeaderData(closeAllInputFieldPanels: () => closed++),
        initialStoreState: (s) => s
          ..showEnvPanel.value = true
          ..showChatVariablePanel.value = true
          ..showDebugAndPreviewPanel.value = true,
      );
      await t.tap(find.bySemanticsLabel('workflow.globalVar.title'));
      expect(s.showGlobalVariablePanel.value, isTrue);
      expect(s.showEnvPanel.value, isFalse);
      expect(s.showChatVariablePanel.value, isFalse);
      expect(s.showDebugAndPreviewPanel.value, isFalse);
      expect(closed, 1);
    });

    testWidgets('should keep the button disabled when the disabled prop is true', (t) async {
      final s = await renderWorkflowComponent(t, const GlobalVariableButton(disabled: true));
      await t.tap(find.bySemanticsLabel('workflow.globalVar.title'), warnIfMissed: false);
      expect(isEnabled(t, 'workflow.globalVar.title'), isFalse);
      expect(s.showGlobalVariablePanel.value, isFalse);
    });
  });

  group('VersionHistoryButton', () {
    testWidgets('should call onClick when the button is clicked', (t) async {
      var clicks = 0;
      await renderWorkflowComponent(t, VersionHistoryButton(onClick: () => clicks++));
      await t.tap(find.bySemanticsLabel('workflow.common.versionHistory'));
      expect(clicks, 1);
    });

    testWidgets('should trigger onClick when the version history shortcut is pressed', (t) async {
      var clicks = 0;
      await renderWorkflowComponent(t, VersionHistoryButton(onClick: () => clicks++));
      final mod = DifyPlatformKeys.mod;
      await t.sendKeyDownEvent(mod);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyH);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(mod);
      expect(clicks, 1);
      final hotkey = t.widget<PageHotkey>(find.byType(PageHotkey));
      expect(hotkey.hotkey, 'Mod+Shift+H');
      expect(hotkey.ignoreInputs, isTrue);
    });

    testWidgets('should render the tooltip popup content on hover', (t) async {
      await renderWorkflowComponent(t, VersionHistoryButton(onClick: () {}));
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(t.getCenter(find.bySemanticsLabel('workflow.common.versionHistory')));
      await t.pump(const Duration(milliseconds: 800));
      await settle(t);
      expect(find.text('workflow.common.versionHistory'), findsOneWidget);
    });
  });
}

/// The key `Mod` stands for on the test platform.
abstract final class DifyPlatformKeys {
  static LogicalKeyboardKey get mod =>
      defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
}
