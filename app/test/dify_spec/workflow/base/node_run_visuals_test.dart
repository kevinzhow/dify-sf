// dify-spec: web/app/components/workflow/nodes/_base/__tests__/node-sections.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/__tests__/node.spec.tsx
//
// NodeHeaderMeta, NodeBody and NodeDescription are parts of dify-sf's card (DifyNodeCard): the header meta is
// [NodeHeaderMeta] (the run part on live cards), the description is the card's NodeDescription row.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/cards/card_chrome.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../nodes_panel/core/harness.dart';

/// A document node from Dify's node data.
Node node(String type, [Map<String, Object?> data = const {}, String title = 'Node title']) => difyNodes([
  {
    ...difyNode('node-1', type, data, title),
    // React Flow's node size (containers are sized by it).
    'width': ?data['width'],
    'height': ?data['height'],
  },
]).single;

/// The card of [n] with [run], live, as the canvas draws it.
Future<CanvasNode> renderCard(WidgetTester t, Node n, {NodeRunView run = NodeRunView.idle}) async {
  useDifyTestTranslator();
  final graph = CanvasGraph(layoutOf: const DifyCards().layoutOf)..sync(Document(nodes: [n]));
  final c = graph[n.id]!;
  c.run.value = run;
  c.cardRun.value = run.forCard;
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: c.layout.visual.size,
            child: DifyNodeCard(node: c, graph: graph, live: true),
          ),
        ),
      ),
    ),
  );
  return c;
}

Future<void> renderMeta(WidgetTester t, Node n, NodeRunView run) async {
  useDifyTestTranslator();
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Center(
          child: NodeHeaderMeta(node: n, run: run),
        ),
      ),
    ),
  );
}

void main() {
  group('node sections', () {
    testWidgets('should render loop and loading metadata in the header section', (t) async {
      await renderMeta(t, node('loop'), const NodeRunView(runningStatus: 'running', loopIndex: 2));
      expect(find.text('workflow.nodes.loop.currentLoopCount:{"count":2}'), findsOneWidget);
      expect(find.byKey(const Key('status-spinner')), findsOneWidget);
      // `animate-spin`: the loader turns.
      expect(
        find.descendant(of: find.byKey(const Key('status-spinner')), matching: find.byType(RotationTransition)),
        findsOneWidget,
      );
    });

    testWidgets('should render the container node body and description branches', (t) async {
      // The container's body grows to the node's size (the card sits 1 px inside the node element).
      final loop = await renderCard(t, node('loop', {'width': 400, 'height': 250, 'desc': 'hidden'}));
      expect(loop.layout.card.size, const Size(398, 248));
      expect(t.getSize(find.byType(DifyNodeCard)), const Size(398, 248));
      await renderCard(t, node('tool', {'desc': 'node description'}));
      expect(find.text('node description'), findsOneWidget);
    });

    testWidgets('should render iteration parallel metadata and running progress', (t) async {
      await renderMeta(
        t,
        node('iteration', {'is_parallel': true}),
        const NodeRunView(runningStatus: 'running', iterationLength: 3, iterationIndex: 5),
      );
      // `system-2xs-medium-uppercase`: shown upper case.
      final badge = find.text('WORKFLOW.NODES.ITERATION.PARALLELMODEUPPER');
      expect(badge, findsOneWidget);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(t.getCenter(badge));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 200));
      expect(
        find.textContaining('workflow.nodes.iteration.parallelModeEnableTitle', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('workflow.nodes.iteration.parallelModeEnableDesc', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('3/3'), findsOneWidget);
    });

    testWidgets('should render failed, exception, success and paused status icons', (t) async {
      for (final (status, icon) in const [
        ('failed', 'error-warning-fill'),
        ('exception', 'alert-fill'),
        ('succeeded', 'checkbox-circle-fill'),
        ('paused', 'pause-circle-fill'),
      ]) {
        await renderMeta(t, node('tool'), NodeRunView(runningStatus: status));
        expect(find.byKey(Key('status-$icon')), findsOneWidget, reason: status);
      }
    });

    testWidgets(
      'should render success icon when inspect vars exist without running status and hide description for non-description nodes',
      (t) async {
        await renderMeta(t, node('tool'), const NodeRunView(hasVarValue: true));
        expect(find.byKey(const Key('status-checkbox-circle-fill')), findsOneWidget);
        await renderCard(t, node('loop', {'width': 400, 'height': 250, 'desc': 'hidden'}));
        expect(find.text('hidden'), findsNothing);
        await renderCard(t, node('start-placeholder', {'desc': 'old placeholder description'}));
        expect(find.text('old placeholder description'), findsNothing);
      },
    );
  });

  group('BaseNode', () {
    testWidgets('should render running status indicators for loop nodes', (t) async {
      await renderCard(
        t,
        // Wider than Dify's 320: the test translator's key text is long.
        node('loop', {'width': 800, 'height': 220}),
        run: const NodeRunView(runningStatus: 'running', loopIndex: 3),
      );
      expect(find.textContaining('workflow.nodes.loop.currentLoopCount'), findsOneWidget);
      expect(find.byKey(const Key('status-spinner')), findsOneWidget);
    });
  });
}
