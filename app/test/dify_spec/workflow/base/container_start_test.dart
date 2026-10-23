// dify-spec: web/app/components/workflow/nodes/iteration-start/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/loop-start/__tests__/index.spec.tsx
//
// IterationStartNode / LoopStartNode are the `iteration-start` / `loop-start` cards on the canvas (with the canvas's
// `out-<id>` source handle); their Dumb variants are ContainerStartNodeDumb, drawn in the container candidate
// being placed (`_isCandidate && <IterationStartNodeDumb />`).
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/cards/bodies/entry_bodies.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../block_selector/harness.dart' show pumpSelector, setUpBlockSelectorTests;
import '../context_menu/harness.dart' show Harness;
import '../nodes_panel/core/harness.dart' show difyNodes;

/// The canvas over a [container] (iteration or loop) holding its start node.
Future<Harness> _canvas(WidgetTester t, String container) async {
  t.view.physicalSize = const Size(1200, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final h = await Harness.start(
    t,
    difyNodes([
      {
        'id': 'container',
        'type': 'custom',
        'position': {'x': 100, 'y': 100},
        'width': 500,
        'height': 300,
        'data': {'type': container, 'title': 'Container', 'start_node_id': '$container-start-node'},
      },
      {
        'id': '$container-start-node',
        'type': 'custom-$container-start',
        'parentId': 'container',
        'position': {'x': 24, 'y': 68},
        'data': {'type': '$container-start', 'title': '', 'desc': ''},
      },
    ]),
  );
  await t.pumpWidget(
    MaterialApp(
      home: WorkflowCanvas(controller: h.controller, canvas: h.canvas),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return h;
}

/// A container candidate being placed (operator/add-block's `_isCandidate: true`).
Future<void> _candidate(WidgetTester t, String type) async {
  final store = WorkflowStore()
    ..setMousePosition((pageX: 100, pageY: 100, elementX: 20, elementY: 20))
    ..setCandidateNode({
      'id': 'candidate',
      'type': 'custom',
      'position': {'x': 0, 'y': 0},
      'data': {'type': type, 'title': 'Candidate', '_isCandidate': true},
    });
  final canvas = CanvasController();
  addTearDown(canvas.dispose);
  await pumpSelector(
    t,
    SizedBox(
      width: 800,
      height: 600,
      child: CandidateNode(canvas: canvas, onPlace: (_) {}),
    ),
    store: store,
  );
}

Future<void> _sourceHandle(WidgetTester t, String container) async {
  final h = await _canvas(t, container);
  expect(find.byKey(Key('out-$container-start-node')), findsOneWidget);
  final card = h.canvas.graph!['$container-start-node']!;
  expect(card.layout.target, isFalse);
  expect(card.layout.sources.keys, ['source']);
  await t.pumpWidget(const SizedBox());
  await h.dispose(t);
}

Future<void> _dumb(WidgetTester t, String container) async {
  await _candidate(t, container);
  expect(find.byType(ContainerStartNodeDumb), findsOneWidget);
  expect(find.byType(ContainerStartIcon), findsOneWidget);
  expect(find.byWidgetPredicate((w) => w.key is Key && '${w.key}'.contains('out-')), findsNothing);
}

void main() {
  setUpBlockSelectorTests();

  group('IterationStartNode', () {
    group('Rendering', () {
      testWidgets('should render the source handle in the ReactFlow context', (t) => _sourceHandle(t, 'iteration'));
      testWidgets('should render the dumb variant without any source handle', (t) => _dumb(t, 'iteration'));
    });
  });

  group('LoopStartNode', () {
    group('Rendering', () {
      testWidgets('should render the source handle in the ReactFlow context', (t) => _sourceHandle(t, 'loop'));
      testWidgets('should render the dumb variant without any source handle', (t) => _dumb(t, 'loop'));
    });
  });
}
