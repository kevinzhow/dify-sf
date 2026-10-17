// dify-spec: web/app/components/workflow/__tests__/candidate-node.spec.tsx
// dify-spec: web/app/components/workflow/__tests__/candidate-node-main.spec.tsx
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> _node(String id, String type, Map<String, Object?> data) => {
  'id': id,
  'type': type,
  'position': {'x': 0, 'y': 0},
  'data': {'_isCandidate': true, ...data},
};

void main() {
  setUpBlockSelectorTests();

  late WorkflowStore store;
  late CanvasController canvas;
  late List<CandidatePlacement> placed;

  setUp(() {
    store = WorkflowStore();
    canvas = CanvasController();
    canvas.view.scale = 1.5;
    canvas.view.viewport = const Size(800, 600);
    placed = [];
  });

  Future<void> render(WidgetTester t) => pumpSelector(
    t,
    SizedBox(
      width: 800,
      height: 600,
      child: CandidateNode(canvas: canvas, onPlace: placed.add),
    ),
    store: store,
  );

  group('CandidateNode', () {
    testWidgets('should not render when candidateNode is missing from the workflow store', (t) async {
      await render(t);
      expect(find.byType(CandidateNodeMain), findsNothing);
    });

    testWidgets('should render CandidateNodeMain with the stored candidate node', (t) async {
      store.setCandidateNode(_node('candidate-node-1', 'custom', {'type': 'start', 'title': 'Candidate node'}));
      await render(t);
      expect(t.widget<CandidateNodeMain>(find.byType(CandidateNodeMain)).candidate['id'], 'candidate-node-1');
    });
  });

  group('CandidateNodeMain', () {
    Future<Offset> clickAt(WidgetTester t) async {
      const at = Offset(120, 220);
      final origin = t.getTopLeft(find.byType(CandidateNodeMain));
      await t.tapAt(at);
      await t.pump();
      return canvas.view.toCanvas(at - origin);
    }

    testWidgets('should render the candidate node and commit a webhook node on click', (t) async {
      store.setMousePosition((pageX: 100, pageY: 200, elementX: 30, elementY: 40));
      store.setCandidateNode(
        _node('candidate-webhook', 'custom', {'type': 'trigger-webhook', 'title': 'WEBHOOK CANDIDATE'}),
      );
      await render(t);
      expect(find.text('WEBHOOK CANDIDATE'), findsOneWidget);
      final card = find.ancestor(of: find.text('WEBHOOK CANDIDATE'), matching: find.byType(Positioned)).first;
      expect(t.widget<Positioned>(card).left, 30);
      expect(t.widget<Positioned>(card).top, 40);
      final scale = find.ancestor(of: find.text('WEBHOOK CANDIDATE'), matching: find.byType(Transform)).first;
      expect(t.widget<Transform>(scale).transform.getMaxScaleOnAxis(), 1.5);

      final at = await clickAt(t);
      final p = placed.single;
      expect(p.node['id'], 'candidate-webhook');
      expect(p.node['position'], {'x': at.dx, 'y': at.dy});
      expect((p.node['data']! as Map)['_isCandidate'], isFalse);
      expect(p.historyEvent, 'NodeAdd');
      expect(store.candidateNode.value, isNull);
      expect(p.generateWebhookUrl, isTrue);
      expect(p.selectNode, isFalse);
    });

    testWidgets('should save note candidates as notes and select the inserted note', (t) async {
      store.setCandidateNode(_node('candidate-note', 'custom-note', {'type': 'code', 'title': 'Note Candidate'}));
      await render(t);
      await clickAt(t);
      expect(placed.single.historyEvent, 'NoteAdd');
      expect(placed.single.selectNode, isTrue);
    });

    testWidgets('should sync draft immediately when committing an Agent v2 node', (t) async {
      store.setCandidateNode(
        _node('candidate-agent-v2', 'custom', {
          'type': 'agent',
          'title': 'Agent Candidate',
          'agent_binding': {'binding_type': 'roster_agent', 'agent_id': 'agent-1'},
          'agent_node_kind': 'dify_agent',
          'version': '2',
        }),
      );
      await render(t);
      await clickAt(t);
      final data = placed.single.node['data']! as Map<String, Object?>;
      expect(data['agent_binding'], {'binding_type': 'roster_agent', 'agent_id': 'agent-1'});
      expect(data['_isCandidate'], isFalse);
      expect(placed.single.syncDraft, isTrue);
      expect(placed.single.createInlineAgentBinding, isFalse);
    });

    testWidgets('should create inline binding before syncing a start-from-scratch Agent v2 node', (t) async {
      store.setCandidateNode(
        _node('candidate-inline-agent-v2', 'custom', {
          'type': 'agent',
          'title': 'Agent Candidate',
          'agent_binding': {'binding_type': 'inline_agent'},
          'agent_node_kind': 'dify_agent',
          'version': '2',
        }),
      );
      await render(t);
      await clickAt(t);
      final p = placed.single;
      final data = p.node['data']! as Map<String, Object?>;
      expect(p.createInlineAgentBinding, isTrue);
      expect(p.deselectOthers, isTrue);
      expect(data['agent_binding'], {'binding_type': 'inline_agent'});
      expect(data['selected'], isTrue);
      expect(data['_isTempNode'], isTrue);
      expect(p.syncDraft, isTrue);
    });

    testWidgets('should append iteration and loop start helper nodes for control-flow candidates', (t) async {
      store.setCandidateNode(
        _node('candidate-iteration', 'custom', {'type': 'iteration', 'title': 'Iteration Candidate'}),
      );
      await render(t);
      await clickAt(t);
      expect(placed.last.node['id'], 'candidate-iteration');
      expect(placed.last.startNode!['id'], 'candidate-iterationstart');
      expect(placed.last.startNode!['parentId'], 'candidate-iteration');

      store.setCandidateNode(_node('candidate-loop', 'custom', {'type': 'loop', 'title': 'Loop Candidate'}));
      await t.pump();
      await clickAt(t);
      expect(placed.last.node['id'], 'candidate-loop');
      expect(placed.last.startNode!['id'], 'candidate-loopstart');
    });

    testWidgets('should clear the candidate node on contextmenu', (t) async {
      store.setCandidateNode(_node('candidate-context', 'custom', {'type': 'code', 'title': 'Context Candidate'}));
      await render(t);
      await t.tapAt(const Offset(200, 200), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await t.pump();
      expect(store.candidateNode.value, isNull);
      expect(placed, isEmpty);
    });
  });
}
