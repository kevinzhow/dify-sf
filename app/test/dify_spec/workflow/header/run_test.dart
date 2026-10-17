// dify-spec: web/app/components/workflow/header/__tests__/run-mode.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/run-and-history.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/test-run-menu.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/test-run-menu-helpers.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/checklist_item.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/header/hotkey.dart';
import 'package:dify_sf_app/src/workflow_editor/header/run_and_history.dart';
import 'package:dify_sf_app/src/workflow_editor/header/test_run_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

TriggerOption createOption({
  String id = 'user-input',
  TriggerType type = TriggerType.userInput,
  String name = 'User Input',
  bool enabled = true,
}) => TriggerOption(id: id, type: type, name: name, nodeType: 'start', enabled: enabled);

void main() {
  group('RunMode', () {
    late List<TriggerOption> runs;
    late List<String> stops;
    late List<(HeaderToastType, String)> toasts;
    WorkflowHeaderData data({List<ChecklistItem> warnings = const [], bool canRun = true}) {
      runs = [];
      stops = [];
      toasts = [];
      return WorkflowHeaderData(
        canRun: canRun,
        graph: ValueNotifier(
          WorkflowGraphFacts(
            nodes: const [HeaderNode(id: 'start-node', type: 'start', title: 'Start')],
            checklist: warnings,
          ),
        ),
        onRun: runs.add,
        onStopRun: stops.add,
        toast: (type, m) => toasts.add((type, m)),
      );
    }

    testWidgets('should render the run trigger and start the workflow when a valid trigger is selected', (t) async {
      await renderWorkflowComponent(t, const RunMode(), data: data());
      expect(find.text('workflow.common.run'), findsOneWidget);
      await t.tap(find.text('workflow.common.run'));
      expect(runs.single.type, TriggerType.userInput);
      expect(runs.single.nodeId, 'start-node');
    });

    testWidgets('should show an error toast instead of running when the selected trigger has checklist warnings', (
      t,
    ) async {
      await renderWorkflowComponent(
        t,
        const RunMode(),
        data: data(
          warnings: const [ChecklistItem(id: 'start-node', type: 'start', title: 'Start', canNavigate: true)],
        ),
      );
      await t.tap(find.text('workflow.common.run'));
      expect(toasts, [(HeaderToastType.error, 'workflow.panel.checklistTip')]);
      expect(runs, isEmpty);
    });

    testWidgets('should render the running state and stop the workflow when it is already running', (t) async {
      await renderWorkflowComponent(
        t,
        const RunMode(),
        data: data(),
        initialStoreState: (s) => s.setWorkflowRunningData({
          'result': {'status': 'running'},
          'task_id': 'task-1',
        }),
      );
      expect(find.text('workflow.common.running'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('workflow.debug.variableInspect.trigger.stop'));
      expect(stops, ['task-1']);
    });

    testWidgets('should render the listening label when the workflow is listening', (t) async {
      await renderWorkflowComponent(t, const RunMode(), data: data(), initialStoreState: (s) => s.setIsListening(true));
      expect(find.text('workflow.common.listening'), findsOneWidget);
    });

    testWidgets('should register the test run menu shortcut as a page command outside text inputs', (t) async {
      await renderWorkflowComponent(t, const RunMode(), data: data());
      final hotkey = t.widget<PageHotkey>(find.byType(PageHotkey));
      expect(hotkey.hotkey, 'Alt+R');
      expect(hotkey.ignoreInputs, isTrue);
    });

    testWidgets('should keep the run trigger visible and disabled when workflow run permission is denied', (t) async {
      await renderWorkflowComponent(
        t,
        const RunMode(),
        data: data(canRun: false),
        initialStoreState: (s) => s.setWorkflowRunningData({
          'result': {'status': 'running'},
          'task_id': 'task-1',
        }),
      );
      expect(isEnabled(t, RegExp('workflow.common.run')), isFalse);
      expect(find.bySemanticsLabel('workflow.debug.variableInspect.trigger.stop'), findsNothing);
      await t.tap(find.text('workflow.common.run'), warnIfMissed: false);
      expect(runs, isEmpty);
    });
  });

  group('RunAndHistory', () {
    testWidgets('should keep the test run button visible and disabled when workflow run permission is denied', (
      t,
    ) async {
      await renderWorkflowComponent(
        t,
        const RunAndHistory(showRunButton: true, runButtonText: 'Test Run'),
        data: const WorkflowHeaderData(canRun: false),
      );
      expect(find.text('Test Run'), findsOneWidget);
      expect(isEnabled(t, RegExp('Test Run')), isFalse);
    });

    testWidgets('should keep the preview button visible and disabled when workflow run permission is denied', (
      t,
    ) async {
      await renderWorkflowComponent(
        t,
        const RunAndHistory(showPreviewButton: true),
        data: const WorkflowHeaderData(canRun: false),
      );
      expect(isEnabled(t, 'workflow.common.debugAndPreview'), isFalse);
    });
  });

  group('TestRunMenu', () {
    testWidgets('should run the only enabled option directly and preserve the child click handler', (t) async {
      final selected = <TriggerOption>[];
      var original = 0;
      await renderWorkflowComponent(
        t,
        TestRunMenu(
          options: TestRunOptions(userInput: createOption()),
          onSelect: selected.add,
          builder: (context, activate) => DifyButton(
            onPressed: () {
              original++;
              activate();
            },
            child: const Text('Run now'),
          ),
        ),
      );
      await t.tap(find.text('Run now'));
      expect(original, 1);
      expect(selected.single.id, 'user-input');
    });

    testWidgets('should expose toggle via ref and select a shortcut when multiple options are available', (t) async {
      final selected = <TriggerOption>[];
      final ref = TestRunMenuController();
      await renderWorkflowComponent(
        t,
        Column(
          children: [
            DifyButton(onPressed: ref.toggle, child: const Text('Toggle via ref')),
            TestRunMenu(
              controller: ref,
              options: TestRunOptions(
                userInput: createOption(),
                runAll: createOption(id: 'run-all', type: TriggerType.all, name: 'Run All'),
                triggers: [createOption(id: 'trigger-1', type: TriggerType.webhook, name: 'Webhook Trigger')],
              ),
              onSelect: selected.add,
              builder: (context, activate) => DifyButton(onPressed: activate, child: const Text('Open menu')),
            ),
          ],
        ),
      );
      await t.tap(find.text('Toggle via ref'));
      await settle(t);
      expect(find.text('~'), findsOneWidget);

      await t.sendKeyEvent(LogicalKeyboardKey.digit0);
      expect(selected.single.id, 'run-all');
    });

    testWidgets('should ignore disabled options in the rendered menu', (t) async {
      await renderWorkflowComponent(
        t,
        TestRunMenu(
          options: TestRunOptions(
            userInput: createOption(enabled: false),
            runAll: createOption(id: 'run-all', type: TriggerType.all, name: 'Run All'),
            triggers: [createOption(id: 'trigger-1', type: TriggerType.webhook, name: 'Webhook Trigger')],
          ),
          onSelect: (_) {},
          builder: (context, activate) => DifyButton(onPressed: activate, child: const Text('Open menu')),
        ),
      );
      await t.tap(find.text('Open menu'));
      await settle(t);
      expect(find.text('User Input'), findsNothing);
      expect(find.text('Webhook Trigger'), findsOneWidget);
    });
  });

  group('test-run-menu helpers', () {
    testWidgets('should normalize shortcut keys and render option rows with clickable shortcuts', (t) async {
      expect(getNormalizedShortcutKey('`'), '~');
      expect(getNormalizedShortcutKey('1'), '1');
      final selected = <TriggerOption>[];
      final option = createOption();
      await renderWorkflowComponent(
        t,
        DifyDropdownMenu(
          open: true,
          builder: (context, c) => const SizedBox(width: 10, height: 10),
          children: [TestRunOptionRow(option: option, shortcutKey: '1', onSelect: selected.add)],
        ),
      );
      await settle(t);
      expect(find.text('1'), findsOneWidget);
      await t.tap(find.text('User Input'));
      expect(selected, [option]);
    });

    testWidgets('should handle shortcut key presses only when the menu is open and the event is eligible', (t) async {
      final selected = <TriggerOption>[];
      final option = createOption(id: 'run-all', type: TriggerType.all, name: 'Run All');
      Widget shortcuts(bool open) => TestRunShortcuts(
        open: open,
        shortcutMappings: [(option: option, shortcutKey: '~')],
        onSelect: selected.add,
        child: const SizedBox(),
      );
      await renderWorkflowComponent(t, shortcuts(true));

      await t.sendKeyEvent(LogicalKeyboardKey.backquote);
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.backquote);
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.backquote);
      await t.sendKeyRepeatEvent(LogicalKeyboardKey.backquote);
      await t.sendKeyUpEvent(LogicalKeyboardKey.backquote);
      expect(selected, [option, option]); // the plain press and the first press of the held key; not the repeat

      selected.clear();
      await renderWorkflowComponent(t, shortcuts(false));
      await t.sendKeyEvent(LogicalKeyboardKey.backquote);
      expect(selected, isEmpty);

      await t.pumpWidget(const SizedBox());
      await t.sendKeyEvent(LogicalKeyboardKey.backquote);
      expect(selected, isEmpty);
    });
  });
}
