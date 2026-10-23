// dify-spec: web/app/components/workflow/__tests__/workflow-history-store.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final nodes = <DifyJson>[
  {
    'id': 'node-1',
    'type': 'custom',
    'position': {'x': 0, 'y': 0},
    'data': {'title': 'Start', 'desc': '', 'type': 'start', 'selected': true},
    'selected': true,
  },
];

final edges = <DifyJson>[
  {
    'id': 'edge-1',
    'source': 'node-1',
    'target': 'node-2',
    'sourceHandle': null,
    'targetHandle': null,
    'type': 'custom',
    'selected': true,
    'data': {'sourceType': 'start', 'targetType': 'end'},
  },
];

WorkflowStore createStore() {
  final workflowStore = WorkflowStore();
  workflowStore.temporal.pause();
  workflowStore.setWorkflowHistory(WorkflowHistoryState(nodes: nodes, edges: edges));
  workflowStore.temporal.clear();
  workflowStore.temporal.resume();
  return workflowStore;
}

void main() {
  group('workflow history store', () {
    testWidgets('sanitizes selected flags when history state is replaced through the exposed store api', (t) async {
      final workflowStore = createStore();
      addTearDown(workflowStore.dispose);
      late WorkflowHistoryStore store;
      await t.pumpWidget(
        WorkflowStoreScope(
          store: workflowStore,
          child: Builder(
            builder: (context) {
              store = WorkflowHistoryStore.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      store.setState(WorkflowHistoryState(nodes: nodes, edges: edges));

      expect((store.getState().nodes[0]['data'] as Map)['selected'], false);
      expect(store.getState().edges[0]['selected'], false);
    });

    testWidgets('throws when consumed outside the provider', (t) async {
      await t.pumpWidget(
        Builder(
          builder: (context) {
            WorkflowHistoryStore.of(context);
            return const SizedBox();
          },
        ),
      );
      expect(
        t.takeException(),
        isA<StateError>().having((e) => e.message, 'message', 'Missing WorkflowStoreScope in the tree'),
      );
    });
  });
}
