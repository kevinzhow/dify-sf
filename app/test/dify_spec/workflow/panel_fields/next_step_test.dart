// dify-spec: web/app/components/workflow/nodes/_base/components/next-step/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/next-step/__tests__/operator.spec.tsx
//
// Branch names and add-button labels are `uppercase` in Dify; the widgets upper-case them.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<void> renderComponent(
  WidgetTester t,
  Node selected,
  List<Node> nodes,
  List<Edge> edges, {
  List<({String id, String name})> targetBranches = const [],
}) {
  final branches = nextStepBranches(
    node: selected,
    nodes: {for (final n in nodes) n.id: n},
    edges: edges,
    targetBranches: targetBranches,
  );
  return render(t, NextStep(nodeType: selected.type, branches: branches, readonly: true), width: 400);
}

Finder upper(String s) => find.text(s.toUpperCase());

void main() {
  group('NextStep', () {
    group('Rendering', () {
      testWidgets('should render connected next nodes and the parallel add action for the default source handle', (
        t,
      ) async {
        const selected = Node(id: 'selected-node', type: 'code', title: 'Selected Node');
        const next = Node(id: 'next-node', type: 'answer', title: 'Next Node');
        await renderComponent(
          t,
          selected,
          [selected, next],
          [
            const Edge(id: 'e', source: 'selected-node', sourceHandle: 'source', target: 'next-node'),
          ],
        );

        expect(find.text('Next Node'), findsOneWidget);
        expect(upper('workflow.common.addParallelNode'), findsOneWidget);
      });

      testWidgets('should render configured branch names when target branches are present', (t) async {
        const selected = Node(id: 'selected-node', type: 'code', title: 'Selected Node');
        const next = Node(id: 'next-node', type: 'answer', title: 'Branch Node');
        await renderComponent(
          t,
          selected,
          [selected, next],
          [const Edge(id: 'e', source: 'selected-node', sourceHandle: 'branch-a', target: 'next-node')],
          targetBranches: const [(id: 'branch-a', name: 'Approved')],
        );

        expect(upper('Approved'), findsOneWidget);
        expect(find.text('Branch Node'), findsOneWidget);
        expect(upper('workflow.common.addParallelNode'), findsOneWidget);
      });

      testWidgets('should number question-classifier branches even when no target node is connected', (t) async {
        const selected = Node(id: 'selected-node', type: 'question-classifier', title: 'Classifier');
        await renderComponent(
          t,
          selected,
          [selected],
          [const Edge(id: 'e', source: 'selected-node', sourceHandle: 'branch-b', target: 'missing-node')],
          targetBranches: const [(id: 'branch-b', name: 'Original branch name')],
        );

        expect(upper('workflow.nodes.questionClassifiers.class 1'), findsOneWidget);
        expect(upper('workflow.panel.selectNextStep'), findsOneWidget);
      });

      testWidgets('should render the failure branch when the node has error handling enabled', (t) async {
        const selected = Node(
          id: 'selected-node',
          type: 'code',
          title: 'Selected Node',
          config: {'error_strategy': VString('fail-branch')},
        );
        const fail = Node(id: 'fail-node', type: 'answer', title: 'Failure Node');
        await renderComponent(
          t,
          selected,
          [selected, fail],
          [
            const Edge(id: 'e', source: 'selected-node', sourceHandle: 'fail-branch', target: 'fail-node'),
          ],
        );

        expect(upper('workflow.common.onFailure'), findsOneWidget);
        expect(find.text('Failure Node'), findsOneWidget);
        expect(upper('workflow.common.addFailureBranch'), findsOneWidget);
      });
    });
  });

  group('NextStep operator', () {
    late List<String> disconnected, deleted;

    Future<void> renderOperator(WidgetTester t) {
      disconnected = [];
      deleted = [];
      return render(
        t,
        Align(
          alignment: Alignment.topRight,
          child: NextStepOperator(
            nodeId: 'node-1',
            sourceHandle: 'source',
            actions: NextStepActions(onDisconnect: disconnected.add, onDelete: deleted.add),
          ),
        ),
      );
    }

    Future<void> open(WidgetTester t) async {
      await t.tap(find.bySemanticsLabel('workflow.common.moreActions'));
      await t.pumpAndSettle();
    }

    testWidgets('opens the menu and keeps the change action available', (t) async {
      await renderOperator(t);
      await open(t);

      expect(find.text('workflow.panel.change'), findsOneWidget);
      expect(find.text('workflow.common.disconnect'), findsOneWidget);
      expect(find.text('common.operation.delete'), findsOneWidget);
    });

    testWidgets('disconnects and deletes the next step from the menu', (t) async {
      await renderOperator(t);

      await open(t);
      await t.tap(find.text('workflow.common.disconnect'));
      await t.pumpAndSettle();
      expect(disconnected, ['node-1']);
      expect(find.text('workflow.common.disconnect'), findsNothing);

      await open(t);
      await t.tap(find.text('common.operation.delete'));
      expect(deleted, ['node-1']);
    });
  });
}
