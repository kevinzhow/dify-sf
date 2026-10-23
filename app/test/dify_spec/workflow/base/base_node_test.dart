// dify-spec: web/app/components/workflow/nodes/_base/__tests__/node.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/__tests__/use-node-resize-observer.spec.tsx
// dify-spec: web/app/components/workflow/nodes/__tests__/index.spec.tsx
//
// BaseNode is dify-sf's DifyNodeCard as the canvas draws it; its title button is the canvas's own semantics node
// for the card (CanvasA11y: title first, tap selects). node.tsx's resize observers on the selected children of
// iterations and loops are ContainerChildSizeObserver; the container's resizer is NodeResizers.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/cards/bodies/basic_bodies.dart' show StartBody;
import 'package:dify_sf_app/src/cards/card_chrome.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/canvas_plus/container_child_size.dart';
import 'package:dify_sf_app/src/workflow_editor/canvas_plus/node_resizers.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import '../context_menu/harness.dart' show Harness;
import '../nodes_panel/core/harness.dart' show difyNodes;
import 'node_run_visuals_test.dart' show node, renderCard, renderMeta;

/// The editor's canvas over the demo document.
Future<({DemoBackend demo, EditorController controller, CanvasController canvas, Future<void> Function() close})>
_canvas(WidgetTester t) async {
  t.view.physicalSize = const Size(1200, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final demo = DemoBackend(withBo: false);
  final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
  await opened.session.start();
  final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
  final canvas = CanvasController();
  await t.pumpWidget(
    MaterialApp(
      home: WorkflowCanvas(controller: controller, canvas: canvas),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return (
    demo: demo,
    controller: controller,
    canvas: canvas,
    close: () async {
      await t.pumpWidget(const SizedBox());
      controller.dispose();
      canvas.dispose();
      await opened.close();
      await demo.dispose();
      await t.pump(const Duration(seconds: 20));
    },
  );
}

/// A container at (50, 70) sized 500 × 400 and its [child] (position relative to the container).
List<Map<String, Object?>> _contained(String type, {double x = 100, double y = 100, String childType = 'tool'}) => [
  {
    'id': 'container',
    'type': 'custom',
    'position': {'x': 50, 'y': 70},
    'width': 500,
    'height': 400,
    'data': {'type': type, 'title': 'Container', 'desc': '', 'width': 500, 'height': 400},
  },
  {
    'id': 'child',
    'type': 'custom',
    'parentId': 'container',
    'position': {'x': x, 'y': y},
    'data': {
      'type': childType,
      'title': 'Child',
      'desc': '',
      if (type == 'iteration') 'isInIteration': true else 'isInLoop': true,
      if (type == 'iteration') 'iteration_id': 'container' else 'loop_id': 'container',
    },
  },
];

/// The canvas overlay layers over [nodes] with Dify's card layouts.
Future<Harness> _overlay(WidgetTester t, List<Map<String, Object?>> nodes) async {
  useDifyTestTranslator();
  final h = await Harness.start(t, difyNodes(nodes));
  final graph = CanvasGraph(layoutOf: const DifyCards().layoutOf)..sync(h.doc);
  h.controller.addListener(() => graph.sync(h.doc));
  h.canvas
    ..graph = graph
    ..view.center = const Offset(400, 300);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: h.store,
          child: Stack(
            children: [
              Positioned.fill(
                child: NodeResizers(controller: h.controller, canvas: h.canvas),
              ),
              ContainerChildSizeObserver(controller: h.controller, canvas: h.canvas),
            ],
          ),
        ),
      ),
    ),
  );
  await Harness.settle(t);
  return h;
}

/// The container's size in the document.
Size _size(Harness h) => nodeResizerSize(h.canvas.graph!['container']!);

Future<void> _select(WidgetTester t, Harness h, String? id) async {
  if (id == null) {
    h.canvas.selection.selectNodes(const []);
  } else {
    h.canvas.selection.selectNodes([h.canvas.graph![id]!.slot]);
  }
  await t.pump();
  await t.pump();
}

/// Gives the child a description, which makes its card taller.
Future<void> _growChild(WidgetTester t, Harness h) async {
  h.controller.setConfig('child', const ['desc'], const VString('A description\nover\nseveral\nlines'));
  await t.pump();
  await t.pump();
}

void main() {
  group('workflow nodes index', () {
    testWidgets('should render the mapped node inside the base node shell', (t) async {
      // CustomNode: DifyCards maps the node's type to its body (NodeComponentMap), drawn inside the card's chrome.
      expect(DifyCards.bodies['start'], isA<StartBody>());
      await renderCard(
        t,
        node('start', {
          'variables': [
            {'variable': 'query', 'label': 'Query', 'type': 'text-input', 'required': true},
          ],
        }, 'Start'),
      );
      final card = find.byType(DifyNodeCard);
      expect(find.descendant(of: card, matching: find.text('START')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('query', findRichText: true)), findsWidgets);
    });
  });

  group('BaseNode', () {
    testWidgets('should render content, handles and description for a regular node', (t) async {
      final c = await renderCard(t, node('tool', {'desc': 'Node description'}));
      // `system-sm-semibold-uppercase`: shown upper case.
      expect(find.text('NODE TITLE'), findsOneWidget);
      expect(find.text('Node description'), findsOneWidget);
      // NodeTargetHandle / NodeSourceHandle: the card's handles.
      expect(c.layout.target, isTrue);
      expect(c.layout.sources.keys, contains('source'));
    });

    testWidgets('should expose the node title area as a selectable button', (t) async {
      final semantics = t.ensureSemantics();
      final e = await _canvas(t);
      final llm = e.controller.doc.nodes.values.firstWhere((n) => n.type == 'llm');
      final button = find.bySemanticsLabel(RegExp('^${RegExp.escape(llm.title)}, llm node'));
      expect(button, findsOneWidget);
      expect(t.getSemantics(button).flagsCollection.isButton, isTrue);
      t.getSemantics(button).owner!.performAction(t.getSemantics(button).id, SemanticsAction.tap);
      await t.pump(const Duration(milliseconds: 300));
      expect(e.controller.selectedNodeId, llm.id);
      await e.close();
      semantics.dispose();
    });

    testWidgets('should keep header metadata outside the selectable button', (t) async {
      final semantics = t.ensureSemantics();
      final e = await _canvas(t);
      final llm = e.controller.doc.nodes.values.firstWhere((n) => n.type == 'llm');
      final button = t.getSemantics(find.bySemanticsLabel(RegExp('^${RegExp.escape(llm.title)}, llm node')));
      // Nothing else (no other button) sits inside the title button.
      expect(button.childrenCount, 0);
      await e.close();
      semantics.dispose();
      // The parallel badge is the header's own part, next to the title.
      await renderMeta(t, node('iteration', {'is_parallel': true}), NodeRunView.idle);
      expect(find.text('WORKFLOW.NODES.ITERATION.PARALLELMODEUPPER'), findsOneWidget);
      expect(find.text('NODE TITLE'), findsNothing);
    });

    testWidgets('should render entry nodes inside the entry container', (t) async {
      final c = await renderCard(t, node('start'));
      expect(find.text('WORKFLOW.ENTRYNODESTATUS.ENABLED'), findsOneWidget);
      // The container wraps the card: the label row sits above it.
      expect(c.layout.visual.top, lessThan(c.layout.card.top));
    });

    testWidgets('should render an iteration node resizer and dimmed overlay', (t) async {
      // The child overflows the iteration on the right (x 400 + 240 > 500).
      final h = await _overlay(t, _contained('iteration', x: 400));
      expect(find.bySemanticsLabel('common.resize.node'), findsOneWidget);
      expect(_size(h).width, 500);
      // (The dimmed install overlay is useNodePluginInstallation's, which needs the plugin marketplace: dify-sf has
      // no plugin installation state.)
      // Selecting the child observes it: its container grows to fit it (handleNodeIterationChildSizeChange).
      await _select(t, h, 'child');
      final child = h.canvas.graph!['child']!.rect, container = h.canvas.graph!['container']!.rect;
      expect(_size(h), Size((child.right - container.left + 16).roundToDouble(), 400));
      await h.dispose(t);
    });

    testWidgets('should trigger loop resize updates when the selected node is inside a loop', (t) async {
      // The child overflows the loop at the bottom.
      final h = await _overlay(t, _contained('loop', y: 360));
      await _select(t, h, 'child');
      final child = h.canvas.graph!['child']!.rect, container = h.canvas.graph!['container']!.rect;
      expect(_size(h), Size(500, (child.bottom - container.top + 20).roundToDouble()));
      // Not an undo step (Dify's rerender saves no history).
      expect(h.controller.undo.canUndo, isFalse);
      await h.dispose(t);
    });
  });

  group('useNodeResizeObserver', () {
    testWidgets('should observe and disconnect when enabled with a mounted node ref', (t) async {
      // The child ends 20 px above the loop's bottom: a taller card overflows it.
      final h = await _overlay(t, _contained('loop', y: 300));
      final height = h.canvas.graph!['child']!.rect.height;
      await h.dispose(t);
      final g = await _overlay(t, _contained('loop', y: 400 - 20 - height - 1));
      await _select(t, g, 'child');
      expect(_size(g), const Size(500, 400));
      // While selected, the card's size change grows the loop.
      await _growChild(t, g);
      final child = g.canvas.graph!['child']!.rect, container = g.canvas.graph!['container']!.rect;
      expect(child.height, greaterThan(height));
      final grown = Size(500, (child.bottom - container.top + 20).roundToDouble());
      expect(grown.height, greaterThan(400));
      expect(_size(g), grown);
      // Deselected, it is no longer observed.
      await _select(t, g, null);
      g.controller.setConfig('child', const ['desc'], const VString('A description\nover\nmany\nmore\nlines\nstill'));
      await t.pump();
      await t.pump();
      expect(g.canvas.graph!['child']!.rect.height, greaterThan(child.height));
      expect(_size(g), grown);
      await g.dispose(t);
    });

    testWidgets('should do nothing when disabled', (t) async {
      final h = await _overlay(t, _contained('loop', y: 360));
      // Not selected: the overflowing child changes nothing.
      await _growChild(t, h);
      expect(_size(h), const Size(500, 400));
      await h.dispose(t);
    });
  });
}
