// dify-spec: web/app/components/workflow/node-actions-menu/__tests__/details.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _more = 'common.operation.more';

void main() {
  setUp(() => DifyI18n.current = NsKeyTranslator());

  group('node actions menu details', () {
    final urls = <String>[];
    setUp(urls.clear);
    WorkflowMenuOptions options({bool running = false, bool chat = false, String? appHref}) => WorkflowMenuOptions(
      isChatMode: chat,
      isSingleRunning: (_) => running,
      onChangeBlock: (_, _) {},
      openUrl: urls.add,
      workflowAppHref: (_) => appHref,
    );

    /// The node's `…` menu, open.
    Future<Harness> open(WidgetTester t, Node n, {WorkflowMenuOptions? o, bool showHelpLink = true}) async {
      final h = await Harness.start(
        t,
        [node('node-0', type: 'start', x: -300), n],
        edges: [Edge(id: 'edge-1', source: 'node-0', sourceHandle: 'branch-a', target: n.id)],
      );
      final actions = h.actions(o ?? options());
      await t.pumpWidget(h.host(NodeActionsDropdown(actions: actions, node: n, showHelpLink: showHelpLink)));
      await t.tap(find.bySemanticsLabel(_more));
      await Harness.settle(t);
      return h;
    }

    Future<void> reopen(WidgetTester t) async {
      await t.tap(find.bySemanticsLabel(_more));
      await Harness.settle(t);
    }

    testWidgets('should run, copy, duplicate, delete, and expose the help link', (t) async {
      final h = await open(t, node('node-1', title: 'Code Node'));
      final deleteStyle = DefaultTextStyle.of(t.element(find.text('common.operation.delete'))).style;
      expect(deleteStyle.color, DifyColors.textSecondary, reason: 'destructive only while highlighted');

      await h.tapText(t, 'workflow.panel.runThisStep');
      expect(h.controller.selectedNodeId, 'node-1');
      expect(h.store.initShowLastRunTab.value, isTrue);
      expect(h.store.pendingSingleRun.value, (nodeId: 'node-1', action: SingleRunAction.run));

      await reopen(t);
      await h.tapText(t, 'workflow.common.copy');
      expect(h.store.clipboardElements.value.single['id'], 'node-1');

      await reopen(t);
      await h.tapText(t, 'workflow.common.duplicate');
      expect(h.doc.nodes.values.where((n) => n.title == 'Code Node (1)'), hasLength(1));

      await reopen(t);
      await h.tapText(t, 'workflow.panel.helpLink');
      expect(urls, ['https://docs.dify.ai/en/self-host/use-dify/nodes/code']);

      await reopen(t);
      await h.tapText(t, 'common.operation.delete');
      expect(h['node-1'], isNull);
      await h.dispose(t);
    });

    testWidgets('should stop the current single run from the run action when the node is running', (t) async {
      final h = await open(t, node('node-1'), o: options(running: true));
      await h.tapText(t, 'workflow.debug.variableInspect.trigger.stop');
      expect(h.controller.selectedNodeId, 'node-1');
      expect(h.store.initShowLastRunTab.value, isTrue);
      expect(h.store.pendingSingleRun.value, (nodeId: 'node-1', action: SingleRunAction.stop));
      await h.dispose(t);
    });

    testWidgets('should hide change action when node is undeletable', (t) async {
      // A chatflow's start node is a singleton and undeletable.
      final h = await open(t, node('node-1', type: 'start'), o: options(chat: true), showHelpLink: false);
      expect(find.text('workflow.panel.runThisStep'), findsOneWidget);
      expect(find.text('workflow.panel.changeBlock'), findsNothing);
      expect(find.text('common.operation.delete'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should render workflow-tool and readonly variants', (t) async {
      final h = await open(
        t,
        node('node-2', type: 'tool', title: 'Workflow Tool'),
        o: options(appHref: '/app/app-123/workflow'),
        showHelpLink: false,
      );
      await h.tapText(t, 'workflow.panel.openWorkflow');
      expect(urls, ['/app/app-123/workflow']);
      await h.dispose(t);

      final r = await Harness.start(t, [node('node-3', type: 'end', title: 'Read only node')]);
      r.store.setCanvasReadOnly(true);
      await t.pumpWidget(
        r.host(NodeActionsDropdown(actions: r.actions(options()), node: r['node-3']!, showHelpLink: false)),
      );
      await reopen(t);
      expect(find.text('workflow.panel.runThisStep'), findsNothing);
      expect(find.text('workflow.common.copy'), findsNothing);
      expect(find.text('common.operation.delete'), findsNothing);
      await r.dispose(t);
    });
  });
}
