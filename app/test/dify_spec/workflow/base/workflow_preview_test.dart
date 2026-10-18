// dify-spec: web/app/components/workflow/workflow-preview/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/workflow-preview/components/__tests__/error-handle-on-node.spec.tsx
// dify-spec: web/app/components/workflow/workflow-preview/components/__tests__/node-handle.spec.tsx
// dify-spec: web/app/components/workflow/workflow-preview/components/__tests__/zoom-in-out.spec.tsx
// dify-spec: web/app/components/workflow/workflow-preview/components/nodes/__tests__/base.spec.tsx
// dify-spec: web/app/components/workflow/workflow-preview/components/nodes/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/workflow-preview/components/nodes/loop/__tests__/hooks.spec.tsx
//
// WorkflowPreview is Dify's read-only copy of the canvas parts (cards, handles, error footer, zoom controls, loop
// growth). dify-sf has one canvas: these cases run against it, its cards (DifyNodeCard with DifyCards' layouts and
// NodeExtras' footer), its handle markers (`in-<id>` / `out-<id>`), the operator's ZoomInOut and the container
// interactions.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/cards/node_extras.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/iteration/container_interactions.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import '../context_menu/harness.dart' show Harness;
import '../nodes_panel/core/harness.dart' show difyNode, difyNodes;
import '../operator/operator_harness.dart' show TestCanvas, pressable, pumpWithStore;
import 'node_run_visuals_test.dart' show node, renderCard;

/// Dify's layout of [n] (handles, size).
CardLayout _layout(Node n) => const DifyCards().layoutOf(n, Document(nodes: [n]));

/// The canvas over [nodes] and [edges].
Future<Harness> _canvas(WidgetTester t, List<Node> nodes, {List<Edge> edges = const []}) async {
  t.view.physicalSize = const Size(1200, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final h = await Harness.start(t, nodes, edges: edges);
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

Future<void> _close(WidgetTester t, Harness h) async {
  await t.pumpWidget(const SizedBox());
  await h.dispose(t);
}

/// Whether the handle marker [key] shows its connection indicator (the `after:` bar).
bool _indicator(String key) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(ColoredBox)).evaluate().isNotEmpty;

/// The last segment of each key (short enough for a card).
class _LastSegment implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => key.split('.').last;
}

class _FitCanvas extends TestCanvas {
  int fits = 0;
  final zooms = <double>[];

  @override
  void fitView({double padding = 0.1}) {
    fits++;
    super.fitView(padding: padding);
  }

  @override
  void zoomTo(double scale) {
    zooms.add(scale);
    super.zoomTo(scale);
  }
}

void main() {
  setUp(useDifyTestTranslator);

  group('WorkflowPreview', () {
    testWidgets('should render a portable Agent v2 node without failing the preview', (t) async {
      await renderCard(
        t,
        node('agent', {
          'version': '2',
          'agent_node_kind': 'dify_agent',
          'desc': 'Handles research tasks',
          'agent_binding': {'binding_type': 'roster_agent', 'package_ref': 'agent_1'},
        }, 'Research Agent'),
      );
      expect(t.takeException(), isNull);
      expect(find.text('RESEARCH AGENT'), findsOneWidget);
      expect(find.text('Handles research tasks'), findsOneWidget);
    });
  });

  group('ErrorHandleOnNode', () {
    group('Rendering', () {
      testWidgets('should render nothing when the node has no error strategy', (t) async {
        final n = node('code');
        await renderCard(t, n);
        expect(find.text('WORKFLOW.COMMON.ONFAILURE'), findsNothing);
        expect(NodeExtras.failBranchY(n), isNull);
        expect(_layout(n).sources.keys, isNot(contains(NodeExtras.failBranch)));
      });

      testWidgets('should render the default-value label', (t) async {
        t.view.physicalSize = const Size(2400, 600);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        useDifyTestTranslator();
        final n = node('code', {'error_strategy': 'default-value'});
        await t.pumpWidget(
          MaterialApp(
            home: Material(
              child: Center(child: SizedBox(width: 2200, child: NodeExtras.build(n))),
            ),
          ),
        );
        expect(find.text('WORKFLOW.COMMON.ONFAILURE'), findsOneWidget);
        expect(find.text('workflow.nodes.common.errorHandle.defaultValue.output'), findsOneWidget);
        // No fail-branch handle.
        expect(_layout(n).sources.keys, isNot(contains(NodeExtras.failBranch)));
      });
    });

    group('Effects', () {
      testWidgets('should render the fail-branch source handle', (t) async {
        t.view.physicalSize = const Size(2400, 600);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        useDifyTestTranslator();
        final n = node('code', {'error_strategy': 'fail-branch'});
        await t.pumpWidget(
          MaterialApp(
            home: Material(
              child: Center(child: SizedBox(width: 2200, child: NodeExtras.build(n))),
            ),
          ),
        );
        expect(find.text('workflow.nodes.common.errorHandle.failBranch.title'), findsOneWidget);
        // On the canvas (short strings: the test translator's keys do not fit a 240 px card), the fail branch has
        // its source handle.
        await t.pumpWidget(const SizedBox());
        DifyI18n.current = _LastSegment();
        final h = await _canvas(
          t,
          difyNodes([
            difyNode('node-1', 'code', {'error_strategy': 'fail-branch'}, 'Node'),
          ]),
        );
        expect(h.canvas.graph!['node-1']!.layout.sources.keys, contains(NodeExtras.failBranch));
        expect(find.byKey(const Key('out-node-1-fail-branch')), findsOneWidget);
        await _close(t, h);
      });
    });
  });

  group('node-handle', () {
    group('NodeTargetHandle', () {
      testWidgets('should hide the connection indicator when the target handle is not connected', (t) async {
        final h = await _canvas(t, difyNodes([difyNode('node-1', 'code', {}, 'Node')]));
        expect(find.byKey(const Key('in-node-1')), findsOneWidget);
        expect(_indicator('in-node-1'), isFalse);
        await _close(t, h);
      });

      testWidgets('should merge custom classes and hide start-like nodes completely', (t) async {
        final h = await _canvas(t, difyNodes([difyNode('node-2', 'start', {}, 'Start')]));
        expect(h.canvas.graph!['node-2']!.layout.target, isFalse);
        expect(find.byKey(const Key('in-node-2')), findsNothing);
        await _close(t, h);
      });
    });

    group('NodeSourceHandle', () {
      testWidgets('should keep the source indicator visible when the handle is connected', (t) async {
        final h = await _canvas(
          t,
          difyNodes([difyNode('node-1', 'code', {}, 'Node'), difyNode('node-2', 'code', {}, 'Next')]),
          edges: [const Edge(id: 'e', source: 'node-1', target: 'node-2')],
        );
        expect(_indicator('out-node-1'), isTrue);
        // The other side of the edge shows its indicator too; an unconnected handle does not.
        expect(_indicator('in-node-2'), isTrue);
        expect(_indicator('out-node-2'), isFalse);
        await _close(t, h);
      });
    });
  });

  group('workflow preview zoom controls', () {
    late WorkflowStore store;
    late _FitCanvas canvas;

    setUp(() {
      store = WorkflowStore();
      canvas = _FitCanvas();
    });

    Future<void> render(WidgetTester t) {
      useDifyTestTranslator();
      return pumpWithStore(t, store, ZoomInOut(canvas: canvas), align: Alignment.bottomRight);
    }

    Finder menu() => find.byWidgetPredicate((w) => w is Semantics && w.properties.role == SemanticsRole.menu);

    Future<void> choose(WidgetTester t, String text) async {
      await t.tap(find.textContaining(RegExp(r'^\d+%$')).first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.descendant(of: menu(), matching: find.text(text)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
    }

    group('Inline Controls', () {
      testWidgets('should zoom out and zoom in when the viewport is within the supported range', (t) async {
        await render(t);
        await t.tap(pressable('workflow.operator.zoomOut'));
        await t.tap(pressable('workflow.operator.zoomIn'));
        expect(canvas.zoomOuts, 1);
        expect(canvas.zoomIns, 1);
      });

      testWidgets('should block zooming out when the viewport is already at the minimum scale', (t) async {
        canvas.view.scale = 0.25;
        await render(t);
        await t.tap(pressable('workflow.operator.zoomOut'), warnIfMissed: false);
        expect(canvas.zoomOuts, 0);
        expect(canvas.view.scale, 0.25);
      });

      testWidgets('should block zooming in when the viewport is already at the maximum scale', (t) async {
        canvas.view.scale = 2;
        await render(t);
        await t.tap(pressable('workflow.operator.zoomIn'), warnIfMissed: false);
        expect(canvas.zoomIns, 0);
        expect(canvas.view.scale, 2);
      });
    });

    group('Preset Menu', () {
      testWidgets('should zoom to %s when selecting that preset', (t) async {
        for (final (label, zoom) in const [('25%', 0.25), ('50%', 0.5), ('75%', 0.75), ('100%', 1.0), ('200%', 2.0)]) {
          canvas.view.scale = zoom == 1 ? 0.5 : 1;
          canvas.zooms.clear();
          await render(t);
          await choose(t, label);
          expect(canvas.zooms, [zoom], reason: label);
          expect(canvas.fits, 0);
        }
      });

      testWidgets('should fit the viewport when selecting the fit option', (t) async {
        await render(t);
        await choose(t, 'workflow.operator.zoomToFit');
        expect(canvas.fits, 1);
        expect(canvas.zooms, isEmpty);
      });
    });
  });

  group('workflow preview base node card', () {
    testWidgets('renders the title, description, child content, and connection handles', (t) async {
      final n = node('answer', {'desc': 'This is a preview node', 'answer': 'Preview answer'}, 'Answer node');
      await renderCard(t, n);
      expect(find.text('ANSWER NODE'), findsOneWidget);
      expect(find.text('This is a preview node'), findsOneWidget);
      // The type's body (the child content): AnswerBody's panel.
      expect(find.text('WORKFLOW.NODES.ANSWER.ANSWER'), findsOneWidget);
      final layout = _layout(n);
      expect(layout.target, isTrue);
      expect(layout.sources.keys, contains('source'));
    });

    testWidgets('uses the iteration layout and parallel badge for iteration nodes', (t) async {
      final n = node('iteration', {
        'desc': 'Ignored description',
        // Wider than Dify's 360: the test translator's badge text is long.
        'width': 800,
        'height': 220,
        'is_parallel': true,
      }, 'Iteration node');
      final c = await renderCard(t, n);
      // The container layout: the card fills the node's size (inside its 1 px frame).
      expect(c.layout.card.size, const Size(798, 218));
      expect(find.text('ITERATION NODE'), findsOneWidget);
      expect(find.text('WORKFLOW.NODES.ITERATION.PARALLELMODEUPPER'), findsOneWidget);
      expect(find.text('Ignored description'), findsNothing);
    });
  });

  group('workflow preview custom node', () {
    testWidgets('renders the mapped node component inside the shared base card', (t) async {
      final n = node('question-classifier', {
        'classes': [
          {'id': 'class-a', 'name': 'Billing'},
        ],
      }, 'Classifier node');
      await renderCard(t, n);
      expect(find.text('CLASSIFIER NODE'), findsOneWidget);
      expect(_layout(n).sources.keys, contains('class-a'));
    });

    testWidgets('renders human input output handles from the mapped node component', (t) async {
      final n = node('human-input', {
        'delivery_methods': <Object?>[],
        'form_content': '',
        'inputs': <Object?>[],
        'user_actions': [
          {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
        ],
        'timeout': 1,
        'timeout_unit': 'hour',
      }, 'Human Input');
      await renderCard(t, n);
      expect(find.text('HUMAN INPUT'), findsOneWidget);
      expect(_layout(n).sources.keys, containsAll(['approve', '__timeout']));
    });
  });

  group('workflow preview loop interactions', () {
    test('expands the loop node when children overflow the current bounds', () {
      final nodes = <Map<String, Object?>>[
        {
          'id': 'loop-node',
          'type': 'custom',
          'position': {'x': 0, 'y': 0},
          'width': 120,
          'height': 80,
          'data': {'type': 'loop', 'title': 'Loop', 'width': 120, 'height': 80},
        },
        {
          'id': 'child-node',
          'type': 'custom',
          'parentId': 'loop-node',
          'position': {'x': 100, 'y': 90},
          'width': 60,
          'height': 40,
          'data': {'type': 'code', 'title': 'Child'},
        },
      ];
      final updated = containerRerender(nodes, 'loop-node')!;
      final loop = updated.firstWhere((n) => n['id'] == 'loop-node');
      expect(loop['width'], 100 + 60 + containerPadding.right);
      expect(loop['height'], 90 + 40 + containerPadding.bottom);
      expect((loop['data']! as Map)['width'], 100 + 60 + containerPadding.right);
    });
  });
}
