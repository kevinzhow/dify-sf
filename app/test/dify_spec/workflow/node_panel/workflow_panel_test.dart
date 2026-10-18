// dify-spec: web/app/components/workflow/nodes/_base/components/workflow-panel/__tests__/index.spec.tsx
//
// BasePanel with dify-sf's node panel: a document in an in-memory session instead of mocked hooks. The plugin auth,
// trigger subscription, data source and unfinished last-run integration cases are listed in the ledger (see
// not_applicable.tsv); a single run is handed to the panel's hooks.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';

Node toolNode({String id = 'node-1', String type = 'tool'}) =>
    node(id, type: type, title: 'Tool Node', config: {'desc': const VString('Node description')});

final bodies = NodePanelBodies({'tool': (context, props) => const Text('panel-child')});

void main() {
  late Harness h;
  late List<String> runs, stops;

  Future<void> render(
    WidgetTester t, {
    WorkflowMenuOptions options = const WorkflowMenuOptions(),
    WorkflowPreferences? preferences,
    Widget? before,
    String id = 'node-1',
    bool runtime = false,
  }) async {
    final panel = WorkflowNodePanel(
      key: ValueKey(id),
      node: h[id]!,
      actions: panelActions(h, options: options),
      bodies: bodies,
      onSingleRun: runs.add,
      onStopSingleRun: stops.add,
    );
    await t.pumpWidget(
      panelApp(
        h,
        runtime ? WorkflowRunHost(controller: h.controller, canvas: h.canvas, child: panel) : panel,
        preferences: preferences,
        before: before,
      ),
    );
    await settle(t);
  }

  setUp(() {
    useDifyTestTranslator();
    SharedPreferences.setMockInitialValues({});
    runs = [];
    stops = [];
  });

  Future<void> start(WidgetTester t, {double? canvas, double width = 480, double other = 200}) async {
    h = await Harness.start(t, [toolNode()]);
    h.store
      ..setNodePanelWidth(width)
      ..setOtherPanelWidth(other);
    if (canvas != null) h.store.setWorkflowCanvasWidth(canvas);
    h.controller.selectNode('node-1');
  }

  group('workflow-panel index', () {
    testWidgets('should render the settings panel and wire title, description, run, and close actions', (t) async {
      await start(t, canvas: 1200);
      await render(t);
      expect(find.text('panel-child'), findsOneWidget);

      await t.enterText(find.byKey(const ValueKey('title-node-1')), 'Updated title');
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(t);
      expect(h['node-1']!.title, 'Updated title');
      expect(h.controller.undo.past.last.event, HistoryEvent.nodeTitleChange);

      await t.enterText(find.byKey(const ValueKey('desc-node-1')), 'Updated description');
      await settle(t, 1000);
      expect(h['node-1']!.config['desc'], const VString('Updated description'));
      expect(h.controller.undo.past.last.event, HistoryEvent.nodeDescriptionChange);

      await t.tap(buttonNamed('workflow.panel.runThisStep'));
      await settle(t);
      await t.tap(buttonNamed('common.operation.close'));
      await settle(t);
      expect(runs, ['node-1']);
      expect(h.controller.selectedNodeId, isNull);
      await h.dispose(t);
    });

    testWidgets('should hide the single-run action when nodes are readonly even with run permission', (t) async {
      await start(t);
      h.store.setCanvasReadOnly(true);
      await render(t);
      expect(buttonNamed('workflow.panel.runThisStep'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should hide the single-run action when run permission is missing', (t) async {
      await start(t);
      await render(t, options: const WorkflowMenuOptions(canRun: false));
      expect(buttonNamed('workflow.panel.runThisStep'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should render last-run content when the tab switches', (t) async {
      await start(t);
      h.store.setInitShowLastRunTab(true);
      await render(t);
      expect(find.byType(LastRun), findsOneWidget);
      expect(find.text('panel-child'), findsNothing);
      expect(h.store.initShowLastRunTab.value, isFalse);

      await t.tap(find.text('WORKFLOW.DEBUG.SETTINGSTAB'));
      await settle(t);
      expect(find.text('panel-child'), findsOneWidget);
      await t.tap(find.text('WORKFLOW.DEBUG.LASTRUNTAB'));
      await settle(t);
      expect(find.byType(LastRun), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('should keep the settings panel visible when single-run params have no forms', (t) async {
      await start(t);
      h.store.setNodeRunData('node-1', {'_isSingleRun': true});
      await render(t, runtime: true);
      expect(find.text('panel-child'), findsOneWidget);
      expect(find.byType(BeforeRunForm), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should react to pending single run actions', (t) async {
      await start(t);
      h.store.setPendingSingleRun((nodeId: 'node-1', action: SingleRunAction.run));
      await render(t);
      expect(runs, ['node-1']);
      expect(h.store.pendingSingleRun.value, isNull);

      h.store.setPendingSingleRun((nodeId: 'node-1', action: SingleRunAction.stop));
      await settle(t);
      expect(stops, ['node-1']);
      expect(runs, hasLength(1));
      await h.dispose(t);
    });

    testWidgets('should stop a running node and offset when the log modal is visible', (t) async {
      // The message log modal's offset is not ported: the stop half of the case.
      await start(t);
      await render(t, options: WorkflowMenuOptions(isSingleRunning: (id) => id == 'node-1'));
      await t.tap(buttonNamed('workflow.debug.variableInspect.trigger.stop'));
      await settle(t);
      expect(stops, ['node-1']);
      expect(runs, isEmpty);
      await h.dispose(t);
    });

    testWidgets('should resize the node panel with the keyboard, persist its width, and allow focus to leave', (
      t,
    ) async {
      await start(t, canvas: 1200);
      final preferences = WorkflowPreferences();
      await render(
        t,
        preferences: preferences,
        before: TextButton(onPressed: () {}, child: const Text('Before panel')),
      );
      final before = Focus.of(t.element(find.text('Before panel')));

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(before.hasFocus, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(separatorFocused(t), isTrue);
      expect(separator(t).label, 'workflow.panel.nodePanel');

      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(t);
      expect(panelWidth(t), 488);
      expect(separator(t).value, 488);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(t);
      expect(panelWidth(t), 520);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(t);
      expect(panelWidth(t), 480);
      expect(separator(t).value, 480);
      expect((await SharedPreferences.getInstance()).getString('workflow-node-panel-width'), '480');

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(separatorFocused(t), isFalse);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(separatorFocused(t), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(before.hasFocus, isTrue);
      preferences.dispose();
      await h.dispose(t);
    });

    testWidgets('should constrain keyboard resizing to the available space and keep unrelated keys untouched', (
      t,
    ) async {
      await start(t, canvas: 1200);
      final passedOn = <LogicalKeyboardKey>[];
      await t.pumpWidget(
        panelApp(
          h,
          Focus(
            canRequestFocus: false,
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent) passedOn.add(e.logicalKey);
              return KeyEventResult.handled;
            },
            child: WorkflowNodePanel(node: h['node-1']!, actions: panelActions(h), bodies: bodies),
          ),
        ),
      );
      await settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(separatorFocused(t), isTrue);
      expect(separator(t).min, 400);
      expect(separator(t).max, 600);

      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(separator(t).value, 400);
      await t.sendKeyEvent(LogicalKeyboardKey.end);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump();
      expect(separator(t).value, 600);
      expect(passedOn, isEmpty);

      h.store.setOtherPanelWidth(300);
      await settle(t);
      expect(separator(t).value, 500);
      expect(separator(t).max, 500);
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.sendKeyEvent(LogicalKeyboardKey.end);
      await t.pump();
      expect(separator(t).value, 500);

      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(separator(t).value, 500);
      expect(passedOn, [LogicalKeyboardKey.arrowDown]);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(separator(t).value, 500);
      await h.dispose(t);
    });

    testWidgets('compresses the node panel when the preview grows without replacing the saved node width', (t) async {
      SharedPreferences.setMockInitialValues({'workflow-node-panel-width': '600'});
      await start(t, canvas: 1400, width: 600, other: 400);
      final preferences = WorkflowPreferences();
      await render(t, preferences: preferences);
      expect(separator(t).value, 600);

      h.store.setOtherPanelWidth(600);
      await settle(t);
      expect(separator(t).value, 400);
      expect(separator(t).max, 400);
      expect((await SharedPreferences.getInstance()).getString('workflow-node-panel-width'), '600');
      preferences.dispose();
      await h.dispose(t);
    });

    testWidgets('should compress oversized panel widths', (t) async {
      await start(t, canvas: 800, width: 600);
      await render(t);
      expect(panelWidth(t), 400);
      await h.dispose(t);
    });
  });
}
