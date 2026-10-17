// dify-spec: web/app/components/workflow/__tests__/selection-contextmenu.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUp(() => DifyI18n.current = NsKeyTranslator());

  group('SelectionContextmenu', () {
    List<String>? snippet;
    setUp(() => snippet = null);
    WorkflowMenuOptions options({bool permission = true}) =>
        WorkflowMenuOptions(canCreateSnippet: permission, onCreateSnippet: (ids) => snippet = ids);

    /// [nodes] with all but [unselected] selected, and the selection menu open on the first node.
    Future<Harness> open(
      WidgetTester t,
      List<Node> nodes, {
      List<Edge> edges = const [],
      Set<String> unselected = const {},
      WorkflowMenuOptions? o,
    }) async {
      final h = await Harness.start(t, nodes, edges: edges);
      await t.pumpWidget(h.app(options: o ?? options()));
      h.select([
        for (final n in nodes)
          if (!unselected.contains(n.id)) n.id,
      ]);
      await h.rightClick(t, h.graph[nodes.first.id]!.visual.topLeft + const Offset(1, 1));
      return h;
    }

    final two = [node('n1'), node('n2', x: 140)];

    testWidgets('should not render when selection context menu target is absent', (t) async {
      final h = await Harness.start(t, two);
      await t.pumpWidget(h.app());
      expect(find.text('workflow.operator.vertical'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should render menu items when selection context menu target is present', (t) async {
      final h = await open(t, two);
      expect(h.store.contextMenuTarget.value, WorkflowContextMenuTarget.selection);
      expect(find.text('workflow.operator.alignLeft'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('should render and execute copy/duplicate/delete operations', (t) async {
      final h = await open(t, two);
      await h.tapText(t, 'workflow.common.copy');
      expect(h.store.clipboardElements.value.map((n) => n['id']), ['n1', 'n2']);
      expect(h.store.contextMenuTarget.value, isNull);

      await h.rightClick(t, h.nodePoint('n1'));
      await h.tapText(t, 'workflow.common.duplicate');
      expect(h.doc.nodes, hasLength(4));
      expect(h.store.contextMenuTarget.value, isNull);

      await h.rightClick(t, h.nodePoint('n1'));
      await h.tapText(t, 'common.operation.delete');
      expect(h.doc.nodes.keys, isNot(contains('n1')));
      expect(h.doc.nodes.keys, isNot(contains('n2')));
      expect(h.doc.nodes, hasLength(2));
      expect(h.store.contextMenuTarget.value, isNull);
      await h.dispose(t);
    });

    testWidgets('should open create snippet dialog with selected graph from the top menu item', (t) async {
      final h = await open(
        t,
        [...two, node('n3', x: 260)],
        edges: const [
          Edge(id: 'a', source: 'n1', target: 'n2'),
          Edge(id: 'b', source: 'n2', target: 'n3'),
        ],
        unselected: {'n3'},
      );
      await h.tapText(t, 'workflow.snippet.createDialogTitle');
      expect(snippet, ['n1', 'n2']);
      expect(h.store.contextMenuTarget.value, isNull);
      await h.dispose(t);
    });

    testWidgets('should hide create snippet action without snippets create-and-modify permission', (t) async {
      final h = await open(t, two, o: options(permission: false));
      expect(find.text('workflow.common.copy'), findsOneWidget);
      expect(find.text('workflow.snippet.createDialogTitle'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should hide create snippet when selection contains %s node', (t) async {
      for (final type in ['answer', 'end', 'start']) {
        final h = await open(t, [node('n1', type: type), node('n2', x: 140)]);
        expect(find.text('workflow.common.copy'), findsOneWidget);
        expect(find.text('workflow.snippet.createDialogTitle'), findsNothing);
        await h.dispose(t);
      }
    });

    testWidgets('should stay hidden when only one node is selected', (t) async {
      final h = await open(t, [node('n1')]);
      expect(h.menuOpen && find.text('workflow.operator.alignLeft').evaluate().isNotEmpty, isFalse);
      await h.dispose(t);
    });

    testWidgets('should align selected nodes to the left and save history', (t) async {
      final h = await open(
        t,
        [node('n1', x: 20, y: 40, w: 40, h: 20), node('n2', x: 140, y: 90, w: 60, h: 30)],
        edges: const [Edge(id: 'e', source: 'n1', target: 'n2')],
      );
      h.store
        ..setHelpLineHorizontal((top: 10, left: 0, width: 10))
        ..setHelpLineVertical((top: 0, left: 10, height: 10));
      await h.tapText(t, 'workflow.operator.alignLeft');
      expect(h['n1']!.x, 20);
      expect(h['n2']!.x, 20);
      expect(h.store.contextMenuTarget.value, isNull);
      expect(h.store.helpLineHorizontal.value, isNull);
      expect(h.store.helpLineVertical.value, isNull);
      expect(h.controller.undo.past.last.event, HistoryEvent.nodeDragStop);
      await h.dispose(t);
    });

    testWidgets('should distribute selected nodes horizontally', (t) async {
      final h = await open(t, [
        node('n1', y: 10, w: 20, h: 20),
        node('n2', x: 100, y: 20, w: 20, h: 20),
        node('n3', x: 300, y: 30, w: 20, h: 20),
      ]);
      await h.tapText(t, 'workflow.operator.distributeHorizontal');
      expect(h['n2']!.x, 150);
      await h.dispose(t);
    });

    testWidgets('should ignore child nodes when the selected container is aligned', (t) async {
      final h = await open(t, [
        node('container', type: 'iteration', x: 200, w: 100, h: 80),
        node('child', x: 10, y: 10, w: 30, h: 20, parent: 'container'),
        node('other', x: 40, y: 60, w: 40, h: 20),
      ]);
      await h.tapText(t, 'workflow.operator.alignLeft');
      expect(h['container']!.x, 40);
      expect(h['other']!.x, 40);
      expect(h['child']!.x, 10);
      await h.dispose(t);
    });

    testWidgets('should cancel when align bounds cannot be resolved', (t) async {
      final h = await open(t, [node('n1', w: 0, h: 0), node('n2', x: 80, y: 20, w: 0, h: 0)]);
      await h.tapText(t, 'workflow.operator.alignLeft');
      expect(h.store.contextMenuTarget.value, isNull);
      expect(h['n2']!.x, 80);
      await h.dispose(t);
    });

    testWidgets('should cancel without aligning when nodes are read only', (t) async {
      final h = await open(t, [node('n1', w: 40, h: 20), node('n2', x: 80, y: 20, w: 40, h: 20)]);
      h.store.setCanvasReadOnly(true);
      await h.tapText(t, 'workflow.operator.alignLeft');
      expect(h.store.contextMenuTarget.value, isNull);
      expect(h['n1']!.x, 0);
      expect(h['n2']!.x, 80);
      await h.dispose(t);
    });

    testWidgets('should cancel when alignable nodes shrink to one item', (t) async {
      final h = await open(t, [
        node('container', type: 'iteration', w: 40, h: 20),
        node('child', x: 80, y: 20, w: 40, h: 20, parent: 'container'),
      ]);
      await h.tapText(t, 'workflow.operator.alignLeft');
      expect(h.store.contextMenuTarget.value, isNull);
      expect(h['container']!.x, 0);
      expect(h['child']!.x, 80);
      await h.dispose(t);
    });
  });
}
