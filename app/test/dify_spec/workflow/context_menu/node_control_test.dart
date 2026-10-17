// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/node-control.spec.tsx
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _run = 'workflow.panel.runThisStep', _more = 'common.operation.more';

void main() {
  setUp(() => DifyI18n.current = NsKeyTranslator());

  group('NodeControl', () {
    Future<Harness> control(
      WidgetTester t, {
      String type = 'code',
      WorkflowMenuOptions options = const WorkflowMenuOptions(),
    }) async {
      final h = await Harness.start(t, [node('node-1', type: type)]);
      await t.pumpWidget(h.host(NodeControl(actions: h.actions(options), node: h['node-1']!)));
      return h;
    }

    group('Single Run Actions', () {
      testWidgets('should trigger a single run through the workflow store', (t) async {
        final h = await control(t);
        await t.tap(find.bySemanticsLabel(_run));
        await Harness.settle(t);
        expect(h.store.initShowLastRunTab.value, isTrue);
        expect(h.store.pendingSingleRun.value, (nodeId: 'node-1', action: SingleRunAction.run));
        expect(h.controller.selectedNodeId, 'node-1');
        await h.dispose(t);
      });

      testWidgets('should trigger stop when the node is already single-running', (t) async {
        final h = await control(t, options: WorkflowMenuOptions(isSingleRunning: (_) => true));
        await t.tap(find.bySemanticsLabel('workflow.debug.variableInspect.trigger.stop'));
        await Harness.settle(t);
        expect(h.store.pendingSingleRun.value, (nodeId: 'node-1', action: SingleRunAction.stop));
        expect(h.controller.selectedNodeId, 'node-1');
        await h.dispose(t);
      });
    });

    group('Availability', () {
      testWidgets('should keep the panel operator available when the plugin is install-locked', (t) async {
        // Placed by the context menus layer: a locked node's control shows while it is selected, not on hover.
        final h = await Harness.start(t, [node('node-1', x: 100, y: 100)]);
        await t.pumpWidget(h.app(options: WorkflowMenuOptions(pluginInstallLocked: (_) => true)));
        h.canvas.selection.hover(h.graph['node-1']!.slot);
        await Harness.settle(t);
        expect(find.bySemanticsLabel(_more), findsNothing);
        h.select(['node-1']);
        await Harness.settle(t);
        expect(find.bySemanticsLabel(_more), findsOneWidget);
        await h.dispose(t);
      });

      testWidgets('should hide the run control when single-node execution is not supported', (t) async {
        final h = await control(t, type: 'end');
        expect(find.bySemanticsLabel(_run), findsNothing);
        expect(find.bySemanticsLabel(_more), findsOneWidget);
        await h.dispose(t);
      });

      testWidgets('should hide the run control when workflow run permission is missing', (t) async {
        final h = await control(t, options: const WorkflowMenuOptions(canEdit: false, canRun: false));
        expect(find.bySemanticsLabel(_run), findsNothing);
        expect(find.bySemanticsLabel(_more), findsOneWidget);
        await h.dispose(t);
      });

      testWidgets('should hide the run control when nodes are read-only', (t) async {
        final h = await Harness.start(t, [node('node-1')]);
        h.store.setCanvasReadOnly(true);
        await t.pumpWidget(h.host(NodeControl(actions: h.actions(), node: h['node-1']!)));
        expect(find.bySemanticsLabel(_run), findsNothing);
        expect(find.bySemanticsLabel(_more), findsOneWidget);
        await h.dispose(t);
      });
    });
  });
}
